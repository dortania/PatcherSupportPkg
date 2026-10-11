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
        rate = (((AMDStat_Compute_SALU_Inst_Cycles + AMDStat_Compute_VALU_Inst_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    else
        rate = (((AMDStat_Shader_SALU_Cycles + AMDStat_Shader_VALU_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;

    return (rate > 100 ? 100 : rate);
}

function ShaderCoreStall()
{
    var OtherActive = (((AMDStat_Shader_SMEM_Cycles + AMDStat_Shader_VMEM_Cycles + AMDStat_Shader_EXP_Cycles + AMDStat_Shader_SCA_Cycles + AMDStat_Shader_MISC_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    var AllActive = ShaderCoreALUActive() + OtherActive;
    if (AllActive >= MTLStatShaderCost)
        return 0;
    else
        return MTLStatShaderCost - AllActive;
}

function ShaderCoreVertexALUActive()
{
    var rate = (((AMDStat_Vertex_SALU_Inst_Cycles + AMDStat_Vertex_VALU_Inst_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    return (rate > 100 ? 100 : rate);
}

function ShaderCoreFragmentALUActive()
{
    var rate = (((AMDStat_Fragment_SALU_Inst_Cycles + AMDStat_Fragment_VALU_Inst_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    return (rate > 100 ? 100 : rate);
}

function ShaderCoreVertexStall()
{
    // Percentage of GPU time that shader core is doing real work for vertex shader.
    var Active = (((AMDStat_Vertex_VALU_Inst_Cycles + AMDStat_Vertex_SALU_Inst_Cycles + AMDStat_Vertex_VMEM_Inst_Cycles + AMDStat_Vertex_SMEM_Inst_Cycles + AMDStat_Vertex_MISC_Inst_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    // (VertexShaderBusyPercentage - Active) is the percentage of GPU time that shader core is being stalled for vertex shader workload.
    if (Active >= MTLStatVertexCost)
        return 0;
    else
        return MTLStatVertexCost - Active;
}

function ShaderCoreFragmentStall()
{
    var Active = (((AMDStat_Fragment_VALU_Inst_Cycles + AMDStat_Fragment_SALU_Inst_Cycles + AMDStat_Fragment_VMEM_Inst_Cycles + AMDStat_Fragment_SMEM_Inst_Cycles + AMDStat_Fragment_MISC_Inst_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    if (Active >= MTLStatFragmentCost)
        return 0;
    else
        return MTLStatFragmentCost - Active;
}

function MemoryStallPerWavefrontCompute()
{
    var MemWait = (AMDStat_Compute_WAIT_CNT_VM > AMDStat_Compute_Wait_Inst_VMEM) ? AMDStat_Compute_WAIT_CNT_VM : AMDStat_Compute_Wait_Inst_VMEM;
    var rate = (MemWait / AMDStat_Compute_Waves_Executed) / AverageWavefrontLatencyCompute() * 100;
    return (rate >= 99) ? 99 : rate;
}

function MemoryStallPerWavefrontVertex()
{
    var MemWait = (AMDStat_Vertex_WAIT_CNT_VM > AMDStat_Vertex_Wait_Inst_VMEM) ? AMDStat_Vertex_WAIT_CNT_VM : AMDStat_Vertex_Wait_Inst_VMEM;
    var rate = (MemWait / AMDStat_Vertex_Waves_Executed) / AverageWavefrontLatencyVertex() * 100;
    return (rate >= 99) ? 99 : rate;
}

function MemoryStallPerWavefrontFragment()
{
    var MemWait = (AMDStat_Fragment_WAIT_CNT_VM > AMDStat_Fragment_Wait_Inst_VMEM) ? AMDStat_Fragment_WAIT_CNT_VM : AMDStat_Fragment_Wait_Inst_VMEM;
    var rate = (MemWait / AMDStat_Fragment_Waves_Executed) / AverageWavefrontLatencyFragment() * 100;
    return (rate >= 99) ? 99 : rate;
}

function MemoryStallPerWavefront()
{
    var MemWait = (AMDStat_Compute_WAIT_CNT_VM > AMDStat_Compute_Wait_Inst_VMEM) ? AMDStat_Compute_WAIT_CNT_VM : AMDStat_Compute_Wait_Inst_VMEM;
    var rate = (MemWait / AMDStat_Compute_Waves_Executed) / AverageWavefrontLatency() * 100;
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

function LdsStallPerWavefront()
{
    var LdsWait = (AMDStat_Compute_WAIT_CNT_LGKM > AMDStat_Compute_LDS_Wait) ? AMDStat_Compute_WAIT_CNT_LGKM : AMDStat_Compute_LDS_Wait;
    var rate = (LdsWait / AMDStat_Compute_Waves_Executed) / AverageWavefrontLatencyCompute() * 100;
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

function ExportStallPerWavefront()
{
    var rate = ((AMDStat_Compute_Wait_Export_Alloc + AMDStat_Compute_WAIT_CNT_EXP) / AMDStat_Compute_Waves_Executed) / AverageWavefrontLatency() * 100;
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

function AverageWavefrontLatency()
{
    return (AMDStat_Compute_Accum_Prev_Cycles/ 4) / AMDStat_Compute_Waves_Executed;
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

function AverageWavesInflight()
{
    return (AMDStat_Compute_Accum_Prev_Cycles / 4) / (NumCUPerSH * NumSH) / AMDStat_Compute_Busy_Cycles;
}

function SamplerBusy()
{
    return AMDStat_SamplerBusy;
}

function L2CacheThroughput()
{
    return (AMDStat_L2CacheRequest / (AMDStat_L2Busy / 100 * AMDStat_GPU_Engine_Busy_Ticks));
}

function ColorBlockDramBandwidth()
{
    if (NumSH == 1)
    {
        return ((AMDStat_CBMemRead + AMDStat_CBMemWritten) / (AMDStat_CBDrawnBusy / 100 * AMDStat_GPU_Engine_Busy_Ticks))* SysClkFreq / 100000;
    }
    else
    {
        return ((AMDStat_CBMemRead + AMDStat_CBMemWritten) / (AMDStat_CBBusy / 100 * AMDStat_GPU_Engine_Busy_Ticks))* SysClkFreq / 100000;
    }
}

function DepthBlockDramBandwidth()
{
    return ((AMDStat_DBTileRead * 8 + AMDStat_DBQuadRead + AMDStat_DBTileWrite + AMDStat_DBQuadWrite) / (AMDStat_ZUnitBusy / 100 * AMDStat_GPU_Engine_Busy_Ticks)) * SysClkFreq / 100000;
}

function L2CacheDramBandwidth()
{
    return ((AMDStat_WriteSize + AMDStat_FetchSize) / (AMDStat_L2Busy / 100 * AMDStat_GPU_Engine_Busy_Ticks)) * SysClkFreq / 100000;
}

function VSInvocation()
{
    if (AMDStat_DSInvocations == 0)
        return AMDStat_VSInvocations;
    else
        return AMDStat_DSInvocations;
}

function CSInvocation()
{
    if (AMDStat_VSInvocations == 0 && AMDStat_PSInvocations !=0)
        return AMDStat_PSInvocations;
    else
        return AMDStat_CSInvocations;
}

function PSInvocation()
{
    if (AMDStat_VSInvocations == 0 && AMDStat_PSInvocations !=0)
        return 0;
    else
        return AMDStat_PSInvocations;
    
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
    if (AMDStat_HSInvocations == 0)
        return AMDStat_IAVertices;
    else
        return AMDStat_VSVerticesIn;
}

function NumberOfPatchesSubmitted()
{
    if (AMDStat_HSInvocations > 0)
        return AMDStat_IAVertices;
    else
        return 0;
}

function VerticesReused()
{
    if (AMDStat_VerticesReuse != 0)
    {
        return (AMDStat_IAVertices - AMDStat_VSInvocations);
    }
    else
        return 0;
}

function VerticesReusedPercentage()
{
    return (VerticesReused() * 100 / AMDStat_IAVertices);
}

function VerticesRendered()
{
    return AMDStat_VSVerticesIn;
}

function VerticesRenderedPercentage()
{
    return (AMDStat_VSVerticesIn * 100 / VerticesSubmitted());
}

function AverageTessFactor()
{
    if (AMDStat_HSInvocations > 0)
        return (AMDStat_VSVerticesIn / AMDStat_IAVertices);
    else
        return 0;
}

function PrimitivesSubmitted()
{
    if (AMDStat_HSInvocations > 0)
        return AMDStat_CInvocations;
    else
        return AMDStat_IAPrimitives;
}

function PrimitivesRendered()
{
    return AMDStat_CPrimitives;
}

function PrimitivesRenderedPercentage()
{
    return (AMDStat_CPrimitives * 100 / PrimitivesSubmitted());
}

function NumberOfCulledPrimitives()
{
    return AMDStat_CulledPrims;
}

function NumberOfCulledPrimitivesPercentage()
{
    return (AMDStat_CulledPrims * 100 / PrimitivesSubmitted());
}

function NumberOfClippedPrimitives()
{
    return AMDStat_ClippedPrims;
}

function NumberOfClippedPrimitivesPercentage()
{
    return (AMDStat_ClippedPrims * 100 / PrimitivesSubmitted());
}

function HierarchicalZTotalTilesCount()
{
    return AMDStat_HiZTilesTotalCount;
}

function HierarchicalZFailPercentage()
{
    return (AMDStat_HiZTilesCulledCount * 100 / AMDStat_HiZTilesTotalCount);
}

function PreZPassSampleCount()
{
    return AMDStat_PreZSamplesPassingZ;
}

function PreZFailSampleCount()
{
    return AMDStat_PreZSamplesFailingZ;
}

function PreZStencilFailSampleCount()
{
    return AMDStat_PreZSamplesFailingS;
}

function PostZPassSampleCount()
{
    return AMDStat_PostZSamplesPassingZ;
}

function PostZFailSampleCount()
{
    return AMDStat_PostZSamplesFailingZ;
}

function PostZStencilFailSampleCount()
{
    return AMDStat_PostZSamplesFailingS;
}

function PixelsRasterized()
{
    return AMDStat_PreHiZTotalQuadsCount * 4;
}

function PreZFailPercentage()
{
    if (AMDStat_FSQuadsCount != 0)
    {
        return (AMDStat_PreZQuadsCount - AMDStat_FSQuadsCount) / AMDStat_PreHiZTotalQuadsCount * 100;
    }
    else
    {
        // This is Z only rendering
        return 0;
    }
}

function PostZFailPercentage()
{
    var PostZFailRate = (AMDStat_PostZSamplesFailingZ + AMDStat_PostZSamplesFailingS) / (AMDStat_PostZSamplesFailingZ + AMDStat_PostZSamplesFailingS + AMDStat_PostZSamplesPassingZ);
    if (AMDStat_PostFSPixels == 0)
    {
        // This is Z only rendering
        return  (AMDStat_PreZQuadsCount * PostZFailRate) / AMDStat_PreHiZTotalQuadsCount * 100;
    }
    else
    {
        return (AMDStat_PostFSPixels * PostZFailRate) / (AMDStat_PreHiZTotalQuadsCount * 4) * 100;
    }
}

function PixelsDrawn()
{
    return AMDStat_PixelsDrawn / NumMRT();
}

function PixelsDrawnPercentage()
{
    return AMDStat_QuadsDrawn / NumMRT() / AMDStat_PreHiZTotalQuadsCount * 100;
}

function FragmentsDrawn()
{
    if (AMDStat_QuadsDrawn == AMDStat_QuadFragmentsDrawn)
    {
        // No MSAA
        return PixelsDrawn();
    }
    else
    {
        return (AMDStat_QuadFragmentsDrawn / NumMRT()) *4;
    }
}

function PixelsDiscardedPercentage()
{
    // Cannot use quad * 4 to get approximation about pixels discarded as discard is usually used when some but not all pixels in a quad need to be discarded.
    return (AMDStat_PSInvocations - AMDStat_PostFSPixels) / (AMDStat_PreHiZTotalQuadsCount * 4) * 100;
}

function PixelRate()
{
    if (NumSH == 1)
    {
        return (AMDStat_PixelsDrawn / (AMDStat_CBDrawnBusy / 100 * AMDStat_GPU_Engine_Busy_Ticks));
    }
    else
    {
        return (AMDStat_PixelsDrawn / (AMDStat_CBBusy / 100 * AMDStat_GPU_Engine_Busy_Ticks));
    }
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

function ALUInstructionPerInvocation()
{
    return ((AMDStat_Compute_SALU_Insts + AMDStat_Compute_VALU_Insts) / AMDStat_Compute_Waves_Executed);
}

function MemInstructionPerInvocationCompute()
{
    return ((AMDStat_Compute_VMEM_WR_Insts + AMDStat_Compute_VMEM_RD_Insts + AMDStat_Compute_SMEM_RD_Insts) / AMDStat_Compute_Waves_Executed);
}

function MemInstructionPerInvocationVertex()
{
    return ((AMDStat_Vertex_VMEM_WR_Insts + AMDStat_Vertex_VMEM_RD_Insts + AMDStat_Vertex_SMEM_RD_Insts) / AMDStat_Vertex_Waves_Executed);
}

function MemInstructionPerInvocationFragment()
{
    return ((AMDStat_Fragment_VMEM_WR_Insts + AMDStat_Fragment_VMEM_RD_Insts + AMDStat_Fragment_SMEM_RD_Insts) / AMDStat_Fragment_Waves_Executed);
}

function MemInstructionPerInvocation()
{
    return ((AMDStat_Compute_VMEM_WR_Insts + AMDStat_Compute_VMEM_RD_Insts + AMDStat_Compute_SMEM_RD_Insts) / AMDStat_Compute_Waves_Executed);
}

function ControlInstructionPerInvocationCompute()
{
    return (AMDStat_Compute_BRANCH_Insts / AMDStat_Compute_Waves_Executed);
}

function ControlInstructionPerInvocationVertex()
{
    return (AMDStat_Vertex_BRANCH_Insts / AMDStat_Vertex_Waves_Executed);
}

function ControlInstructionPerInvocationFragment()
{
    return (AMDStat_Fragment_BRANCH_Insts / AMDStat_Fragment_Waves_Executed);
}

function ControlInstructionPerInvocation()
{
    return (AMDStat_Compute_BRANCH_Insts / AMDStat_Compute_Waves_Executed);
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
    return (AMDStat_ROPStalledTicks / AMDStat_GPU_Engine_Busy_Ticks) * 100;
}

function ZeroAreaCullPrims()
{
    return AMDStat_ZeroAreaCulledPrims;
}

function ZeroAreaCullPrimsPercentage()
{
    return (AMDStat_ZeroAreaCulledPrims * 100 / PrimitivesSubmitted());
}

function ClipperCullPrims()
{
    return AMDStat_ClippingCulledPrims;
}

function ClipperCullPrimsPercentage()
{
    return (AMDStat_ClippingCulledPrims * 100 / PrimitivesSubmitted());
}

function TextureUnitStall()
{
    return AMDStat_TexUnitStall;
}

function TextureUnitBusy()
{
    return AMDStat_TexUnitBusy;
}

function TextureCacheMissRate()
{
    return (AMDStat_TextureCacheMiss / (AMDStat_TextureCacheMiss + AMDStat_TextureCacheHit)) * 100;
}

function VertexMemoryFetchLatency()
{
    return (AMDStat_IAMemReadBin0 * 64 + AMDStat_IAMemReadBin1 * (128 + 64) + AMDStat_IAMemReadBin2 * (128 * 2 + 64) + AMDStat_IAMemReadBin3 * (128 * 3 + 64) + AMDStat_IAMemReadBin4 * (128 * 4 + 64) + AMDStat_IAMemReadBin5 * (128 * 5 + 64) + AMDStat_IAMemReadBin6 * (128 * 6 + 64) + AMDStat_IAMemReadBin7 * (128 * 7 + 64)) / (AMDStat_IAMemReadBin0 + AMDStat_IAMemReadBin1 + AMDStat_IAMemReadBin2 + AMDStat_IAMemReadBin3 + AMDStat_IAMemReadBin4 + AMDStat_IAMemReadBin5 + AMDStat_IAMemReadBin6 + AMDStat_IAMemReadBin7);
}

function NumMRT()
{
    return AMDStat_PostFSExports / AMDStat_PostFSPixels;
}

function PrimitiveRate()
{
    return AMDStat_FrontEndBusy * NumSE / (AMDStat_FrontEndBusy + AMDStat_FrontEndStall + AMDStat_FrontEndStarvedBusy);
}

function VertexRate()
{
    return AMDStat_VSVerticesIn * NumSE / (AMDStat_VSVerticesIn + AMDStat_VSStalledTicks + AMDStat_VSStarvedBusyTicks);
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
    return AMDStat_ParameterCacheStall;
}

function AAMode()
{
    return AMDStat_QuadFragmentsDrawn / AMDStat_QuadDrawn;
}

function TessellatorBusy()
{
    return AMDStat_TessellatorBusy;
}

function CBDrawnBusyRate()
{
    var rate = (AMDStat_CBDrawnBusy / AMDStat_CBBusy) * 100;
    return (rate > 100) ? 100 : rate;
}

