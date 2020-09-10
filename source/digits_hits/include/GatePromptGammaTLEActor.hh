/*----------------------
  GATE version name: gate_v7

  Copyright (C): OpenGATE Collaboration

  This software is distributed under the terms
  of the GNU Lesser General  Public Licence (LGPL)
  See LICENSE.md for further details
  ----------------------*/

#ifndef GATEPROMPTGAMMAPRODUCTIONTLEACTOR_HH
#define GATEPROMPTGAMMAPRODUCTIONTLEACTOR_HH

#include "GateConfiguration.h"
#include "GateVImageActor.hh"
#include "GateActorMessenger.hh"
#include "GatePromptGammaTLEActorMessenger.hh"
#include "GateImageOfHistograms.hh"
#include "GatePromptGammaData.hh"
#include "GateVImageVolume.hh"
#include <G4GeneralParticleSource.hh>
#include <TFile.h>
#include <TH1.h>
#include <TH2.h>
#include <fstream>
#include <iostream>
//-----------------------------------------------------------------------------
class GatePromptGammaTLEActor: public GateVImageActor
{
public:
  virtual ~GatePromptGammaTLEActor();

  FCT_FOR_AUTO_CREATOR_ACTOR(GatePromptGammaTLEActor)

  virtual void Construct();
  virtual void UserPreTrackActionInVoxel(const int index, const G4Track* t);
  virtual void UserPostTrackActionInVoxel(const int index, const G4Track* t);
  virtual void UserSteppingActionInVoxel(const int index, const G4Step* step);
  virtual void BeginOfEventAction(const G4Event * e);
  //virtual void EndOfEventAction(const G4Event * e);

  void SetInputDataFilename(std::string filename);
  virtual void SaveData();
  virtual void ResetData();

  void EnableDebugOutput(bool b) { mIsDebugOutputEnabled = b; }
  void EnableOutputMatch(bool b) { mIsOutputMatchEnabled = b; }
  //void EnableSysVarianceImage(bool b) { mIsSysVarianceImageEnabled = b; }
  //void EnableIntermediaryUncertaintyOutput(bool b) { mIsIntermediaryUncertaintyOutputEnabled = b; }
  double GetEmin() {return mEmin; }
  double GetEmax() {return mEmax;}
  int GetENBins() {return mENBins;}

  double GetTmin() {return Tmin;}
  double GetTmax() {return Tmax;}
  int GetTNbins() {return TNbins;}
protected:
  GatePromptGammaTLEActor(G4String name, G4int depth=0);
  GatePromptGammaTLEActorMessenger * pMessenger;

  std::string mInputDataFilename;
  GatePromptGammaData data;
  bool alreadyHere;

  bool mIsDebugOutputEnabled;
  bool mIsOutputMatchEnabled;

  //helper functions
  void SetTrackIoH(GateImageOfHistograms*&);
  void SetTLEIoH(GateImageOfHistograms*&);
  GateVImageVolume* GetPhantom();
  void BuildVarianceOutput(); //converts trackl,tracklsq into mImageGamma and tlevar per voxel. Not used.
  //void BuildSysVarianceOutput(); //converts trackl into mImageGamma and tlesysvarv. Not used.

  //used and reset each track
  GateImageOfHistograms * tmptrackl;    //l_i

  //updated at end of event:
  GateImageOfHistograms * trackl;       //L_i. also intermediate output: track length per voxel per E_proton
  GateImageOfHistograms * tracklsq;     //L_i^2. also intermediate output: track squared length per voxel per E_proton

  //output, calculated at end of simu
  GateImageOfHistograms * mImagetof;
  GateImageOfHistograms * mImageGamma;  //oldstyle main output,
  GateImageOfHistograms * tle;          //main output (yield)
  GateImageOfHistograms * tlesysvar;    //systematic variance per voxel, per E_gamma. Not used.
  GateImageOfHistograms * tlevariance;  //uncertainty per voxel, per E_gamma. Not used.
  
  double mEmin;
  double mEmax;
  int mENBins;

  double Tmin;
  double Tmax;
  int TNbins;
  bool protonprocess;

  
  GateImageOfHistograms * mTof;
  const static unsigned int sizeX = 35;
  const static unsigned int sizeY = 125;
  const static unsigned int sizeZ = 35;
 

  double lt[sizeX*sizeY*sizeZ]; //Ne marche qu'avec le fantome vpg
  double lt2[sizeX*sizeY*sizeZ];
  double l[sizeX*sizeY*sizeZ];
  double l2[sizeX*sizeY*sizeZ];
  double NProt[sizeX*sizeY*sizeZ];
  
  TH2D * pProtonTimeDistribution[sizeY];
  TH2D * pTime[sizeY];
  int true_index[sizeY];
  TFile * pTfile;
  
  GateImageInt mLastHitEventImage;      //store eventID when last updated.
  int mCurrentEvent;                    //monitor event. TODO: not sure if necesary
    TH2D * pGammaTimeDistribution[sizeY];
};
//-----------------------------------------------------------------------------

MAKE_AUTO_CREATOR_ACTOR(PromptGammaTLEActor,GatePromptGammaTLEActor)

#endif // end GATEPROMPTGAMMAPRODUCTIONTLEACTOR
