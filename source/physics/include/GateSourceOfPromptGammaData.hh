/*----------------------
  GATE version name: gate_v6

  Copyright (C): OpenGATE Collaboration

  This software is distributed under the terms
  of the GNU Lesser General  Public Licence (LGPL)
  See LICENSE.md for further details
  ----------------------*/

/*!
  \class  GateSourceOfPromptGammaData

  Manage a 3D distribution of prompt gamma, with 1 energy spectrum at
  each voxel, stored as TH1D. For voxels with yield==0, the TH1D is not
  instantiated/allocated.

*/

#ifndef GATEPROMPTGAMMASPATIALEMISSIONDISTRIBUTION_HH
#define GATEPROMPTGAMMASPATIALEMISSIONDISTRIBUTION_HH

#include "G4UnitsTable.hh"
#include "G4ParticleMomentum.hh"
#include "G4SPSAngDistribution.hh"
#include "G4SPSPosDistribution.hh"
#include "G4SPSEneDistribution.hh"
#include "GateConfiguration.h"
#include "GateImageOfHistograms.hh"
#include <random>
#include <iostream>
#include <fstream>

//------------------------------------------------------------------------
class GateSourceOfPromptGammaData
{
public:
  GateSourceOfPromptGammaData();
  ~GateSourceOfPromptGammaData();

  void SampleRandomPositionTime(G4ThreeVector & position, G4double & tof);
  void SampleRandomEnergy(double & energy);
  void SampleRandomDirection(G4ParticleMomentum & direction);
  double SampleRandomTime(double avg,double sigma);
  //void ReadToF( double & mean[], double & sigma[]);

  void LoadData(std::string mFilename);
  void Initialize();
  double computesum;
  double ComputeSum() { return computesum; }
  
protected:
  // The 3D prompt gamma distribution
  GateImageOfHistograms * mImage;
  std::vector<float> mDataCounts;

  //double * mean = new double[104125];
  //double * sigma = new double[104125];
  //std::vector<float> mean ;
  
  //std::vector<float> sigma;


  // Current pixel index for position in 3D space
  int mCurrentIndex_i;
  int mCurrentIndex_j;
  int mCurrentIndex_k;

  // Physical coordinates from index coordinate
  std::vector<double> mIndexCoordX;
  std::vector<double> mIndexCoordY;
  std::vector<double> mIndexCoordZ;

  // The angular, position and energy generator
  G4SPSAngDistribution mAngleGen;
  //  std::vector<G4SPSEneDistribution> mEnergyGen;
  std::vector<TH1D*> mEnergyGen;
  G4SPSRandomGenerator mPositionXGen;
  std::vector<G4SPSRandomGenerator*> mPositionYGen;
  std::vector<std::vector<G4SPSRandomGenerator*> > mPositionZGen;

}; // end class
//------------------------------------------------------------------------

#endif /* end #define GATEPROMPTGAMMASPATIALEMISSIONDISTRIBUTION */
