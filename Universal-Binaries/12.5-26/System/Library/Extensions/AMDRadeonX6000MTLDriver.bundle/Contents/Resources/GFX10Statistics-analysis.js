var MemBandWidth = MemClkFreq / 100000 * MemBusWidth / 8 * 2; // GB/s
var MaxPixelRate = NumROP * 4; // Pixels/EngineClk

var waSEVERITY_HIGH = 2;
var waSEVERITY_MEDIUM = 1;
var waSEVERITY_LOW = 0;

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
