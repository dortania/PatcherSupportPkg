// You can reference raw counters by their name
// In this example, raw counters used are
// 		raw_counter1
//		raw_counter2
//		raw_counter3
// 		raw_counter4

// a simple derived counter, the name is derived_counter_1
// it relies on raw_counter1 and raw_counter2
function GPUUtilization()
{
	return (GPU_BusyTics * 100.0) / GPU_CoreClocks;
}

function ShaderCoreActive()
{
	return ((EU_BusyTics * 100.0) / EUCoreCount) / GPU_BusyTics;
}

function ShaderCoreStall()
{
	return ((EU_StallTics * 100.0) / EUCoreCount)/ GPU_BusyTics;
}

function VertexCost()
{
	var VSTime;
	if ((VS_ThreadBusyTics == 0) && (VS_ThreadStallTics == 0))
	{
		//Tessellated draw, report sum of HS+DS
		VSTime = EU_BusyTics + EU_StallTics - (PS_ThreadBusyTics + PS_ThreadStallTics);
	}
	else
	{
		VSTime = VS_ThreadBusyTics + VS_ThreadStallTics;
	}
	return (VSTime)* 100.0 / (EU_BusyTics + EU_StallTics);
}

function PixelCost()
{
	return (PS_ThreadBusyTics + PS_ThreadStallTics) * 100.0 / (EU_BusyTics + EU_StallTics);
}

function GTRingBW()
{
	return (gam_total_reads2ring + gam_total_writes2ring ) * 64 / ( MTLStat_nSec * 1e-9 ) / 1e9
}

function DRAMBW()
{
	return (DRAMReads + DRAMWrites ) * 64 / ( MTLStat_nSec * 1e-9 ) / 1e9
}

function PixelShaderInvocations()
{
	return PsInvocations;
}

function VertexShaderInvocations()
{
	var vertexInvocations = VsInvocations;
	if (VsInvocations == 0)
	{
		//Must be a Tessellated draw, return DS invocations
		vertexInvocations = DsInvocations;
	}
	return vertexInvocations;
}

function NumberOfPatches()
{
	return HsInvocations;
}

function TessFactor()
{
	return (HsInvocations > 0) ? (VertexShaderInvocations()/(TessDomain*HsInvocations)) : 0;
}

function ComputeShaderInvocations()
{
	return CsInvocations;
}

function PixelToVertexRatio()
{
    return (VerticesSubmitted() > 0) ? (PixelsRasterized() / VerticesSubmitted()) : 0;
}

function PixelsPerPrimitive()
{
    return PrimitivesSubmitted() > 0 ? (PixelsRasterized()  / PrimitivesSubmitted()) : 0;
}

function VerticesSubmitted()
{
    return (HsInvocations > 0) ? VertexShaderInvocations() : IAVertices;
}

function VerticesPerClock()
{
	return VerticesSubmitted() / GPU_BusyTics;
}

function VerticesRendered()
{
    var vertRendered;
    if (HsInvocations > 0)
    {
        vertRendered = ClipperPrimitives;
    }
    else
    {
        vertRendered = (ClipperPrimitives * IAVertices)/IAPrimitives;
    }
    return vertRendered;
}

function VerticesRenderedPercent()
{
	return (VerticesRendered() * 100) / VerticesSubmitted();
}

function PrimitivesSubmitted()
{
    return (HsInvocations > 0) ? (VertexShaderInvocations()/TessDomain) : IAPrimitives;
}

function PrimitivesClipped()
{
    var primClipped;
    if (HsInvocations > 0)
    {
        if(VertexShaderInvocations() > ClipperPrimitives)
    	{
        	primClipped = (VertexShaderInvocations() - ClipperPrimitives)/TessDomain;
        }
        else
        {
        	primClipped = (ClipperPrimitives - VertexShaderInvocations())/TessDomain;
        }
    }
    else
    {
        primClipped = (IAPrimitives > ClipperPrimitives) ? (IAPrimitives - ClipperPrimitives) : (ClipperPrimitives - IAPrimitives);
    }
    return primClipped;
}

function PrimitivesClippedPercent()
{
	return (PrimitivesClipped() * 100) / PrimitivesSubmitted();
}

function PrimitivesRendered()
{
    return (HsInvocations > 0) ? (ClipperPrimitives/TessDomain) : ClipperPrimitives;
}

function PrimitivesRenderedPercent()
{
	return (PrimitivesRendered() * 100) / PrimitivesSubmitted();
}

function PixelsFailingHiZ()
{
	return (Pixels_64_FastHIZ_Fail ) + (Pixels_4_SlowHIZ_Fail);
}

function PixelsRasterized()
{
	return PixelShaderInvocations();
}

function PixelsFailingHiZPercent()
{
	return (PixelsFailingHiZ() * 100)/ PixelsRasterized();
}

function PixelsFailingPostPS()
{
	return (OM_AlphaTestsFail + OM_ZtestFail + OM_StencilTestsFail);
}

function PixelsFailingPostPSPercent()
{
	return (PixelsFailingPostPS() * 100)/ PixelsRasterized();
}

function PixelsWrittenToMemory()
{
	return OM_SamplesWritten;
}

function PixelsProcessed()
{
	return DepthCount;
}

function PixelsProcessedPercent()
{
	return PixelsProcessed() * 100 / PixelsRasterized();
}

function PixelsDiscarded()
{
	return Pixels_Killed;
}

function PixelsDiscardedPercent()
{
	return PixelsDiscarded() * 100 / PixelsRasterized();
}

function PixelsWrittenPerClock()
{
	return (PixelsWrittenToMemory() / GPU_BusyTics);
}


function TextureUnitBusy()
{
	var samplerBusy = s0_ss0_sampler_is_busy > s0_ss1_sampler_is_busy ? s0_ss0_sampler_is_busy :s0_ss1_sampler_is_busy;
	return (samplerBusy * 100.0) / GPU_BusyTics;
}

function TextureUnitStalled()
{
	var samplerBottleneck = s0_ss0_sampler_is_bottleneck > s0_ss1_sampler_is_bottleneck ? s0_ss0_sampler_is_bottleneck :s0_ss1_sampler_is_bottleneck;
	return (samplerBottleneck * 100.0) / GPU_BusyTics;
}

