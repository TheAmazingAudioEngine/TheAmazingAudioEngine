//
////////////////////////////////////////////////////////////////////////////////
/*
	rmslevels_t.h
	
	Created by 32BT on 15/11/15.
	Copyright © 2015 32BT. All rights reserved.
*/
////////////////////////////////////////////////////////////////////////////////

#include "rmslevels_t.h"
#include <math.h>


////////////////////////////////////////////////////////////////////////////////

static inline double rms_add(double A, double M, double S)
{ return A + M * (S - A); }

static inline double rms_max(double A, double M, double S)
{ return A > S ? rms_add(A, M, S) : S; }

static inline double rms_min(double A, double M, double S)
{ return A < S ? rms_add(A, M, S) : S; }

////////////////////////////////////////////////////////////////////////////////
#pragma mark
////////////////////////////////////////////////////////////////////////////////

typedef struct rmstarget_t
{
	double mAvg;
	double mMax;

	// interpolation multipliers based on samplerate
	double mAvgM;
	double mMaxM;
	double mHldM;
	double mClpM;
	
	// counters based on samplerate
	double mHldNt;
	double mHldN;
	double mClpN;
	double mClpD;
}
rmstarget_t;

////////////////////////////////////////////////////////////////////////////////

rmsengine_t RMSEngineInit(double sampleRate)
{
	rmsengine_t engine = {
	0.0, 0.0, 0.0, 0.0,
	0.0, 0.0, 0.0, 0.0,
	0.0, 0.0, 0.0, 0.0 };
	
	RMSEngineSetResponse(&engine, 400, sampleRate);
	
	return engine;
}

////////////////////////////////////////////////////////////////////////////////

void RMSEngineSetResponse(rmsengine_t *engine, double milliSeconds, double sampleRate)
{
	double decayRate = 0.001 * milliSeconds * sampleRate;
	
	engine->mAvgM = 1.0 / (1.0 + decayRate);
	engine->mMaxM = 1.0 / (1.0 + decayRate);
	engine->mHldM = 1.0 / (1.0 + decayRate * 10);
	engine->mClpM = 0.0;
	
	// default hold time = 1.0 seconds
	engine->mHldT = 1.0 * sampleRate;
}

////////////////////////////////////////////////////////////////////////////////

void RMSEngineAddSample(rmsengine_t *engine, double sample)
{
	// Compute squared values
	sample *= sample;
	
	// Update average
	engine->mAvg = rms_add(engine->mAvg, engine->mAvgM, sample);
	
	// Update maximum
	engine->mMax = rms_max(engine->mMax, engine->mMaxM, sample);
	
	// Update hold value
	if (engine->mHld < sample)
	{
		engine->mHld = sample;
		engine->mHldN = engine->mHldT;
	}
	else
	if (engine->mHldN > 0.0)
		engine->mHldN -= 1.0;
	else
		engine->mHld = rms_add(engine->mHld, engine->mHldM, sample);
}

////////////////////////////////////////////////////////////////////////////////

void RMSEngineAddSamples32(rmsengine_t *engine, float *srcPtr, uint32_t n)
{
	for (; n!=0; n--)
	RMSEngineAddSample(engine, *srcPtr++);
}

////////////////////////////////////////////////////////////////////////////////

rmslevels_t RMSEngineGetLevels(rmsengine_t *enginePtr)
{
	rmslevels_t levels = RMSLevelsZero;
	
	if (enginePtr != NULL)
	{
		levels.mAvg = sqrt(enginePtr->mAvg);
		levels.mMax = sqrt(enginePtr->mMax);
		levels.mHld = sqrt(enginePtr->mHld);
	}
	
	return levels;
}

////////////////////////////////////////////////////////////////////////////////
// 20.0*log10(sqrt()) == 10.0*log10()

rmslevels_t RMSEngineGetLevelsDB(rmsengine_t *engine)
{
	rmslevels_t levels;
	
	levels.mAvg = 10.0*log10(engine->mAvg);
	levels.mMax = 10.0*log10(engine->mMax);
	
	return levels;
}

////////////////////////////////////////////////////////////////////////////////





