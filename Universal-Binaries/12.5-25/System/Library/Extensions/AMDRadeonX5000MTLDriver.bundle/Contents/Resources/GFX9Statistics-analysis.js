var MemBandWidth = MemClkFreq / 100000 * MemBusWidth / 8 * 2; // GB/s
var MaxPixelRate = NumROP * 4; // Pixels/EngineClk

var waSEVERITY_HIGH = 2;
var waSEVERITY_MEDIUM = 1;
var waSEVERITY_LOW = 0;

function analysis_TextureSamplingInst_bound()
{
    var ALUActiveThreshold = 20;
    var MemoryStallThreshold = 40;
    var ShaderCostThreshold = 70;
    var TextureUnitBusyThreshold = 60;
    var SamplerBusyThreshold = 60;

    var specificShaderStall = false;
    if ((ShaderCoreALUActive < ALUActiveThreshold) && (MemoryStallPerWavefrontCompute > MemoryStallThreshold) && (MTLStatComputeCost > ShaderCostThreshold) && (SamplerBusy > SamplerBusyThreshold))
    {
        specificShaderStall = true;
        var problemId = ReportProblem(0.3, "Compute shader is texture sampling bound", waSEVERITY_HIGH);
        AddProblemSubItem(problemId, "The compute shader has a Low ALU to Memory instruction ratio and a high rate of sampling instruction stalls")
        AddProblemSubItem(problemId, "Optimize texture sampling instructions in the compute shader, or increase the ALU workload to take advantage of stalled cycles", "ComputeShader")
    }
    if ((ShaderCoreALUActive < ALUActiveThreshold) && (MemoryStallPerWavefrontVertex > MemoryStallThreshold) && (MTLStatVertexCost > ShaderCostThreshold) && (SamplerBusy > SamplerBusyThreshold))
    {
        specificShaderStall = true;
        var problemId = ReportProblem(0.3, "Vertex shader is texture sampling bound", waSEVERITY_HIGH);
        AddProblemSubItem(problemId, "The vertex shader has a Low ALU to Memory instruction ratio and a high rate of sampling instruction stalls")
        AddProblemSubItem(problemId, "Optimize texture sampling instructions in the vertex shader, or increase the ALU workload to take advantage of stalled cycles", "VertexShader")
    }
    if ((ShaderCoreALUActive < ALUActiveThreshold) && (MemoryStallPerWavefrontFragment > MemoryStallThreshold) && (MTLStatFragmentCost > ShaderCostThreshold) && (SamplerBusy > SamplerBusyThreshold))
    {
        specificShaderStall = true;
        var problemId = ReportProblem(0.3, "Fragment shader is texture sampling bound", waSEVERITY_HIGH);
        AddProblemSubItem(problemId, "The fragment shader has a Low ALU to Memory instruction ratio and a high rate of sampling instruction stalls")
        AddProblemSubItem(problemId, "Optimize texture sampling instructions in the fragment shader, or increase the ALU workload to take advantage of stalled cycles", "FragmentShader")
    }
    
    if (specificShaderStall == false && (ShaderCoreALUActive < ALUActiveThreshold) && (MemoryStallPerWavefront > MemoryStallThreshold) && (MTLStatShaderCost > ShaderCostThreshold) && (SamplerBusy > SamplerBusyThreshold))
    {
        var problemId = ReportProblem(0.3, "Shading is texture sampling bound", waSEVERITY_HIGH);
        AddProblemSubItem(problemId, "The shaders have a Low ALU to Memory instruction ratio and a high rate of sampling instruction stalls")
        AddProblemSubItem(problemId, "Optimize texture sampling instructions in the shaders, or increase the ALU workload to take advantage of stalled cycles", "BoundResources")
    }

}

function analysis_shaderALU_bound()
{
    var ALUActiveThreshold = 75;
    var ShaderCostThreshold = 70;
    
    if ((ShaderCoreALUActive > ALUActiveThreshold) && (MTLStatVertexCost > ShaderCostThreshold))
    {
        var problemId = ReportProblem(0.3, "Vertex shader is ALU instruction bound", waSEVERITY_HIGH);
        AddProblemSubItem(problemId, "Optimize ALU instructions in the vertex shader", "VertexShader");
    }
    if ((ShaderCoreALUActive > ALUActiveThreshold) && (MTLStatFragmentCost > ShaderCostThreshold))
    {
        var problemId = ReportProblem(0.3, "Fragment shader is ALU instruction bound", waSEVERITY_HIGH);
        AddProblemSubItem(problemId, "Optimize ALU instructions in the fragment shader", "FragmentShader");
    }
    if ((ShaderCoreALUActive > ALUActiveThreshold) && (MTLStatComputeCost > ShaderCostThreshold))
    {
        var problemId = ReportProblem(0.3, "Shader is ALU instruction bound", waSEVERITY_HIGH);
        AddProblemSubItem(problemId, "Optimize ALU instructions in the compute shader", "Kernel");
    }
}

function analysis_memory_bound()
{
    var totalMemBandwidth = ColorBlockDramBandwidth + L2CacheDramBandwidth + DepthBlockDramBandwidth;
    
    if (totalMemBandwidth > (MemBandwidth * 0.7))
    {
        var problemId = ReportProblem(0.3, "Memory bandwidth bound", "Reduce memory access", waSEVERITY_MEDIUM);
        AddProblemSubItem(problemId, "Reduce overall use of memory bandwidth")
    }
}

function analysis_pixelRate_bound()
{
    var blendingOn = (AMDStat_CB_Mem_Read == 0) ? 1 : 2;
    if (PixelRate > ((MaxPixelRate / blendingOn) * 0.8))
    {
        var severity = waSEVERITY_LOW;
        
        if ((NumMRT > 2) || (blendingOn == 2))
        {
            severity = waSEVERITY_MEDIUM;
        }
        
        var problemId = ReportProblem(0.3, "Pixel rate bound", severity);
        AddProblemSubItem(problemId, "Performance is bound by the maximum rate the GPU can write pixels");
        
        if (NumMRT > 2)
        {
            AddProblemSubItem(problemId, "Consider decreasing the number of MRTs if possible");
        }
        
        if (blendingOn == 2)
        {
            AddProblemSubItem(problemId, "Blending is on, which will reduce the maximum pixel rate, check if blending needs to be turned on")
        }
    }
}

function analysis_primitiveRate_bound()
{
    if (AMDStat_FrontEnd_Busy > 0)
    {
        var stallRate = AMDStat_FrontEnd_Stall / AMDStat_GPU_Engine_Busy_Ticks / NumSE;
        var busyRate = AMDStat_FrontEnd_StarvedBusy / AMDStat_GPU_Engine_Busy_Ticks / NumSE;
        var peakPrimitiveRate = NumSE;
        if ((stallRate < 0.3) && (busyRate > 0.6))
        {
            if (PrimitiveRate < (peakPrimitiveRate * 0.4))
            {
                var problemId = ReportProblem(0.3, "Low primitive rate", waSEVERITY_MEDIUM);
                AddProblemSubItem(problemId, "Try to reuse vertices to attain higher primitive rate")
                if (ParameterCacheStall > 70)
                {
                    problemId = ReportProblem(0.3, "Vertex shader output bound", waSEVERITY_HIGH);
                    AddProblemSubItem(problemId, "Optimize the number of attributes output by the vertex shader", "VertexShader")
                }
            }
            else
            {
                var problemId = ReportProblem(0.3, "Front end primitive bound", waSEVERITY_LOW);
                AddProblemSubItem(problemId, "Performance is bound by the maximum rate the GPU can process primitives")
            }
        }
    }
}

