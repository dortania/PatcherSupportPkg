// Bottleneck analysis functions
// They can reference both derived counters and dependent raw counters 
// APIs:
// 	ReportProblem(confidence, problem, severity) -> problemId
//		where: severity is one of SEVERITY_HIGH, SEVERITY_MEDIUM, SEVERITY_LOW
//  AddProblemSubItem(problemId, description[, resourceLink])
//		where: resourceLink is optional and one of "VertexShader", "FragmentShader", "Kernel", "BoundResources", "Attachments"


function is_short_draw()
{
	return (GPU_BusyTics < 15000)
}

function analysis_memory_bound()
{
	// No Analysis for very short draws
	if(is_short_draw())
	{
		return
	}
	// see if there is a problem
	if (DRAMBW > 15.0)
	{
		var confidence = DRAMBW > 18.0 ? 0.8 : 0.5;
		var problemId = ReportProblem(confidence, "Memory bandwidth bound", SEVERITY_MEDIUM)
        AddProblemSubItem(problemId, "Reduce overall use of memory bandwidth")
	}
}

function analysis_pbe_bound()
{
	if(is_short_draw())
	{
		return
	}
	if (PixelsWrittenPerClock > 4.0)
	{
		var confidence = PixelsWrittenPerClock > 8.0 ? 1.0 : 0.5
		var severity = PixelsWrittenPerClock > 8.0 ? SEVERITY_MEDIUM : SEVERITY_LOW
		var problemId = report_problem(confidence, "Pixel rate bound", severity)
		AddProblemSubItem(problemId, "Consider decreasing the size of attachments or the number of MRTs if possible", "Attachments")
	}
}

function analysis_shader_bound()
{
	if(is_short_draw())
	{
		return
	}

	if ((ShaderCoreActive + ShaderCoreStall)> 90.0)
	{
		if (ShaderCoreActive > ShaderCoreStall)
		{
			var outputStr = ""
			var guideStr = ""
			var resourceLink = ""

			// Either VS or PS bound
			if (PixelCost > VertexCost)
			{
				outputStr = "Fragment shader bound";
				guideStr = "Reduce amount of work in the fragment shader"
				resourceLink = "FragmentShader"
			}
			else 
			{
				outputStr = "Vertex shader bound"
				guideStr = "Reduce amount of work in the vertex shader"
				resourceLink = "VertexShader"
			}
			var problemId = ReportProblem(0.8, outputStr, SEVERITY_HIGH)
			AddProblemSubItem(problemId, guideStr, resourceLink)
		}
		else if (ShaderCoreStall > 50)
		{
			if(TextureUnitStalled > 75)
			{
				var problemId = ReportProblem(0.8, "Texture Unit bound", SEVERITY_HIGH)
				AddProblemSubItem(problemId, "Consider reducing the texture sizes or take fewer samples in the shader", "BoundResources")
			}
		}
	}
}

function analysis_vertex_bound()
{
	if(is_short_draw())
	{
		return
	}

	if (VerticesPerClock > 1.0)
	{
		var confidence = VerticesPerClock > 2.0 ? 0.8 : 0.5; 
		var severity = VerticesPerClock > 2.0 ? SEVERITY_MEDIUM : SEVERITY_LOW

		var problemId = ReportProblem(confidence, "Low vertex rate" /* problem */, severity)
		AddProblemSubItem(problemId, "Consider reducing the number of vertices")
	}
}
