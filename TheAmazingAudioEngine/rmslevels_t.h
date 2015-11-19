////////////////////////////////////////////////////////////////////////////////
/*
	rmslevels_t.h
	
	Created by 32BT on 15/11/15.
	Copyright © 2015 32BT. All rights reserved.
*/
////////////////////////////////////////////////////////////////////////////////

#ifndef rmslevels_t_h
#define rmslevels_t_h

#include <stddef.h>
#include <stdint.h>

////////////////////////////////////////////////////////////////////////////////
/*
	usage indication:
	
	// initialize engine struct with samplerate
	rmsengine_t engine = RMSEngineInit(44100);
	
	// on audio thread, for each sample call:
	RMSEngineAddSample(&engine, sample);
	
	// on main thread, periodically call:
	rmslevels levels = RMSEngineGetLevels(&engine);
	
	
*/
////////////////////////////////////////////////////////////////////////////////

// Structure for intermediate sample processing
typedef struct rmsengine_t
{
	double mAvg;
	double mMax;
	double mHld;
	double mClp;

	// multipliers based on samplerate
	double mAvgM;
	double mMaxM;
	double mHldM;
	double mClpM;
	
	//
	double mHldT; // hold time in samples
	double mHldN; // hold time counter
	double mClpN; // nominator, number of clipped samples
	double mClpD; // denominator, number of samples tested
}
rmsengine_t;

////////////////////////////////////////////////////////////////////////////////

// Structure to communicate results
typedef struct rmslevels_t
{
	double mAvg;
	double mMax;
	double mHld;
	double mClp;
}
rmslevels_t;

#define RMSLevelsZero (rmslevels_t){ 0.0, 0.0, 0.0, 0.0 }

////////////////////////////////////////////////////////////////////////////////

// Prepare engine struct using samplerate
rmsengine_t RMSEngineInit(double sampleRate);

// Update values with squared samples
void RMSEngineAddSample(rmsengine_t *engine, double sample);
void RMSEngineAddSamples32(rmsengine_t *engine, float *srcPtr, uint32_t n);

// Get sqrt results. Save to call with enginePtr == nil
rmslevels_t RMSEngineGetLevels(rmsengine_t *enginePtr);

////////////////////////////////////////////////////////////////////////////////

void RMSEngineSetResponse(rmsengine_t *engine, double milliSeconds, double sampleRate);
void RMSEngineSetDecayRate(rmsengine_t *engine, double decayRate);

////////////////////////////////////////////////////////////////////////////////
#endif // rmslevels_t_h
////////////////////////////////////////////////////////////////////////////////






