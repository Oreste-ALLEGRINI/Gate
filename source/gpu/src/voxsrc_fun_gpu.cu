#include "voxsrc_cst_gpu.cu"
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <math.h>
#include <float.h>


/***********************************************************
 * Vars
 ***********************************************************/

// FIXME this must be declared once
texture<unsigned short int, 1, cudaReadModeElementType> tex_phantom;
texture<float, 1, cudaReadModeElementType> tex_act_val;
texture<unsigned int, 1, cudaReadModeElementType> tex_act_ind;
__constant__ const float pi = 3.14159265358979323846;
__constant__ const float twopi = 2*pi;

// Stack of gamma particles, format data is defined as SoA
struct StackGamma{
	float* E;
	float* dx;
	float* dy;
	float* dz;
	float* px;
	float* py;
	float* pz;
	float* t;
	unsigned int* seed;
	unsigned char* interaction;
	unsigned char* live;
	unsigned char* endsimu;
	unsigned char* ct_cpt;
	unsigned char* ct_pe;
	unsigned char* ct_ray;
	unsigned int size;
	unsigned long* table_x_brent;
}; //


/***********************************************************
 * Utils Device
 ***********************************************************/

// function from CLHEP
__device__ float3 deflect_particle(float3 p, float3 dir) {
	float u1 = p.x;
	float u2 = p.y;
	float u3 = p.z;
	float up = u1*u1 + u2*u2;

	if (up>0) {
		up = sqrt(up);
		float px = dir.x,  py = dir.y,  pz = dir.z;
		dir.x = __fdividef(u1*u3*px - u2*py, up) + u1*pz;
		dir.y = __fdividef(u2*u3*px + u1*py, up) + u2*pz;
		dir.z =              -up*px +              u3*pz;
    }
	else if (u3 < 0.) { dir.x = -dir.x; dir.z = -dir.z; }      // phi=0  theta=pi

	return make_float3(dir.x, dir.y, dir.z);
}

//// Return the next voxel boundary distance, it is used by the standard navigator
__device__ float voxsrc_get_boundary_voxel_by_raycasting(int4 vox, float3 p, float3 d, float3 res) {
    
    
	float xmin, xmax, ymin, ymax, zmin, zmax;
    float3 di = make_float3(__fdividef(1.0f, d.x), __fdividef(1.0f, d.y),__fdividef(1.0f, d.z));
	float tmin, tmax, tymin, tymax, tzmin, tzmax, buf;
	
    // Define the voxel bounding box
    xmin = vox.x*res.x;
    ymin = vox.y*res.y;
    zmin = vox.z*res.z;
    xmax = (d.x<0 && p.x==xmin) ? xmin-res.x : xmin+res.x;
    ymax = (d.y<0 && p.y==ymin) ? ymin-res.y : ymin+res.y;
    zmax = (d.z<0 && p.z==zmin) ? zmin-res.z : zmin+res.z;
    
    //printf("Raycasting x %e %e y %e %e z %e %e\n", xmin, xmax, ymin, ymax, zmin, zmax);

    tmin = -1e9f;
    tmax = 1e9f;
    
    // on x
    if (d.x != 0.0f) {
        tmin = (xmin - p.x) * di.x;
        tmax = (xmax - p.x) * di.x;
        if (tmin > tmax) {
            buf = tmin;
            tmin = tmax;
            tmax = buf;
        }
    }
    // on y
    if (d.y != 0.0f) {
        tymin = (ymin - p.y) * di.y;
        tymax = (ymax - p.y) * di.y;
        if (tymin > tymax) {
            buf = tymin;
            tymin = tymax;
            tymax = buf;
        }
        if (tymin > tmin) {tmin = tymin;}
        if (tymax < tmax) {tmax = tymax;}
    }
    // on z
    if (d.z != 0.0f) {
        tzmin = (zmin - p.z) * di.z;
        tzmax = (zmax - p.z) * di.z;
        if (tzmin > tzmax) {
            buf = tzmin;
            tzmin = tzmax;
            tzmax = buf;
        }
        if (tzmin > tmin) {tmin = tzmin;}
        if (tzmax < tmax) {tmax = tzmax;}
    }

    return tmax;
}

/***********************************************************
 * PRNG Brent xor256
 ***********************************************************/

// Brent PRNG integer version
__device__ unsigned long voxsrc_weyl;
__device__ unsigned long voxsrc_Brent_int(unsigned int index, unsigned long *device_x_brent, unsigned long seed)

{
	
#define UINT64 (sizeof(unsigned long)>>3)
#define UINT32 (1 - UINT64) 
#define wlen (64*UINT64 +  32*UINT32)
#define r    (4*UINT64 + 8*UINT32)
#define s    (3*UINT64 +  3*UINT32)
#define a    (37*UINT64 +  18*UINT32)
#define b    (27*UINT64 +  13*UINT32)
#define c    (29*UINT64 +  14*UINT32)
#define d    (33*UINT64 +  15*UINT32)
#define ws   (27*UINT64 +  16*UINT32) 

	int z, z_w, z_i_brent;	
	if (r==4){
		z=6; z_w=4; z_i_brent=5;}
	else{
		z=10; z_w=8; z_i_brent=9;}
	
	unsigned long w = device_x_brent[z*index + z_w];
	unsigned long i_brent = device_x_brent[z*index + z_i_brent];
	unsigned long zero = 0;
	unsigned long t, v;
	int k;
	
	if (seed != zero) { // Initialisation necessary
		// voxsrc_weyl = odd approximation to 2**wlen*(3-sqrt(5))/2.
		if (UINT32) 
			voxsrc_weyl = 0x61c88647;
		else 
			voxsrc_weyl = ((((unsigned long)0x61c88646)<<16)<<16) + (unsigned long)0x80b583eb;
		
		v = (seed!=zero)? seed:~seed;  // v must be nonzero
		
		for (k = wlen; k > 0; k--) {   // Avoid correlations for close seeds
			v ^= v<<10; v ^= v>>15;    // Recurrence has period 2**wlen-1
			v ^= v<<4;  v ^= v>>13;    // for wlen = 32 or 64
		}
		for (w = v, k = 0; k < r; k++) { // Initialise circular array
			v ^= v<<10; v ^= v>>15; 
			v ^= v<<4;  v ^= v>>13;
			device_x_brent[k + z*index] = v + (w+=voxsrc_weyl);              
		}
		for (i_brent = r-1, k = 4*r; k > 0; k--) { // Discard first 4*r results
			t = device_x_brent[(i_brent = (i_brent+1)&(r-1)) + z*index];   t ^= t<<a;  t ^= t>>b;			
			v = device_x_brent[((i_brent+(r-s))&(r-1)) + z*index];	v ^= v<<c;  v ^= v>>d;       
			device_x_brent[i_brent + z*index] = t^v;  
		}
    }
    
	// Apart from initialisation (above), this is the generator
	t = device_x_brent[(i_brent = (i_brent+1)&(r-1)) + z*index]; // Assumes that r is a power of two
	v = device_x_brent[((i_brent+(r-s))&(r-1)) + z*index];       // Index is (i-s) mod r
	t ^= t<<a;  t ^= t>>b;                                       // (I + L^a)(I + R^b)
	v ^= v<<c;  v ^= v>>d;                                       // (I + L^c)(I + R^d)
	device_x_brent[i_brent + z*index] = (v ^= t); 				 // Update circular array                 
	w += voxsrc_weyl;                                                   // Update Weyl generator
	
	device_x_brent[z*index + z_w] = w;
	device_x_brent[z*index + z_i_brent] = i_brent;
	
	return (v + (w^(w>>ws)));  // Return combination
	
#undef UINT64
#undef UINT32
#undef wlen
#undef r
#undef s
#undef a
#undef b
#undef c
#undef d
#undef ws 
}	

// Brent PRNG real version
__device__ double voxsrc_Brent_real(int index, unsigned long *device_x_brent, unsigned long seed)

{
	
#define UINT64 (sizeof(unsigned long)>>3)
#define UINT32 (1 - UINT64) 
#define UREAL64 (sizeof(double)>>3)
#define UREAL32 (1 - UREAL64)
	
	// sr = number of bits discarded = 11 for double, 40 or 8 for float
	
#define sr (11*UREAL64 +(40*UINT64 + 8*UINT32)*UREAL32)
	
	// ss (used for scaling) is 53 or 21 for double, 24 for float
	
#define ss ((53*UINT64 + 21*UINT32)*UREAL64 + 24*UREAL32)
	
	// SCALE is 0.5**ss, SC32 is 0.5**32
	
#define SCALE ((double)1/(double)((unsigned long)1<<ss)) 
#define SC32  ((double)1/((double)65536*(double)65536)) 
	
	double res;
	
	res = (double)0; 
	while (res == (double)0)  // Loop until nonzero result.
    {   // Usually only one iteration.
		res = (double)(voxsrc_Brent_int(index, device_x_brent, seed)>>sr);     // Discard sr random bits.
		seed = (unsigned long)0;                                        // Zero seed for next time.
		if (UINT32 && UREAL64)                                          // Need another call to xor4096i.
			res += SC32*(double)voxsrc_Brent_int(index, device_x_brent, seed); // Add low-order 32 bits.
    }
	return (SCALE*res); // Return result in (0.0, 1.0).
	
#undef UINT64
#undef UINT32
#undef UREAL64
#undef UREAL32
#undef SCALE
#undef SC32
#undef sr
#undef ss
}

// Init Brent seed
__global__ void kernel_voxsrc_Brent_init(StackGamma stackgamma) {
	unsigned int id = __umul24(blockIdx.x, blockDim.x) + threadIdx.x;

	if (id < stackgamma.size) {
		unsigned int seed = stackgamma.seed[id];
		float dummy = voxsrc_Brent_int(id, stackgamma.table_x_brent, seed);
	}
}

/***********************************************************
 * Physics
 ***********************************************************/

// Compton Cross Section Per Atom (Standard - Klein-Nishina)
__device__ float voxsrc_Compton_CSPA_Standard(float E, unsigned short int Z) {
	float CrossSection = 0.0;
	if (Z<1 || E < 1e-4f) {return CrossSection;}

	float p1Z = Z*(2.7965e-23f + 1.9756e-27f*Z + -3.9178e-29f*Z*Z);
	float p2Z = Z*(-1.8300e-23f + -1.0205e-24f*Z + 6.8241e-27f*Z*Z);
	float p3Z = Z*(6.7527e-22f + -7.3913e-24f*Z + 6.0480e-27f*Z*Z);
	float p4Z = Z*(-1.9798e-21f + 2.7079e-24f*Z + 3.0274e-26f*Z*Z);
	float T0 = (Z < 1.5f)? 40.0e-3f : 15.0e-3f;
	float d1, d2, d3, d4, d5;

	d1 = __fdividef(fmaxf(E, T0), 0.510998910f); // X
	CrossSection = __fdividef(p1Z*__logf(1.0f+2.0f*d1), d1) + __fdividef(p2Z + p3Z*d1 + p4Z*d1*d1, 1.0f + 20.0f*d1 + 230.0f*d1*d1 + 440.0f*d1*d1*d1);

	if (E < T0) {
		d1 = __fdividef(T0+1.0e-3f, 0.510998910f); // X
		d2 = __fdividef(p1Z*__logf(1.0f+2.0f*d1), d1) + __fdividef(p2Z + p3Z*d1 + p4Z*d1*d1, 1.0f + 20.0f*d1 + 230.0f*d1*d1 + 440.0f*d1*d1*d1); // sigma
		d3 = __fdividef(-T0 * (d2 - CrossSection), CrossSection*1.0e-3f); // c1
		d4 = (Z > 1.5f)? 0.375f-0.0556f*__logf(Z) : 0.15f; // c2
		d5 = __logf(__fdividef(E, T0)); // y
		CrossSection *= __expf(-d5 * (d3 + d4*d5));
	}

	return CrossSection;
}

// PhotoElectric Cross Section Per Atom (Standard)
__device__ float voxsrc_PhotoElec_CSPA_Standard(float E, unsigned short int Z) {
	 // from Sandia, the same for all Z
	float Emin = fmax(PhotoElec_std_IonizationPotentials[Z]*1e-6f, 0.01e-3f);
	if (E < Emin) {return 0.0f;}
	
	int start = PhotoElec_std_CumulIntervals[Z-1];
	int stop = start + PhotoElec_std_NbIntervals[Z];
	int pos=stop;
	while (E < PhotoElec_std_SandiaTable[pos][0]*1.0e-3f){--pos;}
	float AoverAvo = 0.0103642688246f * __fdividef((float)Z, PhotoElec_std_ZtoAratio[Z]);
	float rE = __fdividef(1.0f, E);
	float rE2 = rE*rE;

	return rE * PhotoElec_std_SandiaTable[pos][1] * AoverAvo * 0.160217648e-22f
		+ rE2 * PhotoElec_std_SandiaTable[pos][2] * AoverAvo * 0.160217648e-25f
		+ rE * rE2 * PhotoElec_std_SandiaTable[pos][3] * AoverAvo * 0.160217648e-28f
		+ rE2 * rE2 * PhotoElec_std_SandiaTable[pos][4] * AoverAvo * 0.160217648e-31f;
}

// Compton Scatter (Standard, Klein-Nishina)
__device__ float3 voxsrc_Compton_scatter_Standard(StackGamma stack, unsigned int id, int* gamma_sim_d) {
	float E = stack.E[id];
	float E0 = __fdividef(E, 0.510998910f);

	float epszero = __fdividef(1.0f, (1.0f + 2.0f * E0));
	float eps02 = epszero*epszero;
	float a1 = -__logf(epszero);
	float a2 = __fdividef(a1, (a1 + 0.5f*(1.0f-eps02)));

	float greject, onecost, eps, eps2, sint2, cosTheta, sinTheta, phi;
	do {
		if (a2 > voxsrc_Brent_real(id, stack.table_x_brent, 0)) {
			eps = __expf(-a1 * voxsrc_Brent_real(id, stack.table_x_brent, 0));
			eps2 = eps*eps;
		} else {
			eps2 = eps02 + (1.0f - eps02) * voxsrc_Brent_real(id, stack.table_x_brent, 0);
			eps = sqrt(eps2);
		}
		onecost = __fdividef(1.0f - eps, eps * E0);
		sint2 = onecost * (2.0f - onecost);
		greject = 1.0f - eps * __fdividef(sint2, 1.0f + eps2);
	} while (greject < voxsrc_Brent_real(id, stack.table_x_brent, 0));

	E *= eps;
	stack.E[id] = E;
	
	if (E <= 1.0e-6f) { // 1 eV
		stack.live[id] = 0;
		stack.endsimu[id] = 1; // stop this particle
        atomicAdd(gamma_sim_d, 1);
		return make_float3(0.0f, 0.0f, 1.0f);
	}

	cosTheta = 1.0f - onecost;
	sinTheta = sqrt(sint2);
	phi = voxsrc_Brent_real(id, stack.table_x_brent, 0) * twopi;

	return make_float3(sinTheta*__cosf(phi), sinTheta*__sinf(phi), cosTheta);
}

// Compute the total Compton cross section for a given material
__device__ float voxsrc_Compton_CS_Standard(int mat, float E) {
	float CS = 0.0f;
	int i;
	int index = mat_index[mat];
	// Model standard
	for (i = 0; i < mat_nb_elements[mat]; ++i) {
		CS += (mat_atom_num_dens[index+i] * voxsrc_Compton_CSPA_Standard(E, mat_mixture[index+i]));
	}
	return CS;
}

// Compute the total Compton cross section for a given material
__device__ float voxsrc_PhotoElec_CS_Standard(int mat, float E) {
	float CS = 0.0f;
	int i;
	int index = mat_index[mat];
	// Model standard
	for (i = 0; i < mat_nb_elements[mat]; ++i) {
		CS += (mat_atom_num_dens[index+i] * voxsrc_PhotoElec_CSPA_Standard(E, mat_mixture[index+i]));
	}
	return CS;
}

/***********************************************************
 * Sources
 ***********************************************************/

// Voxelized back2back source (use the Relative Activity Integral Method)
__global__ void kernel_voxelized_source_b2b(StackGamma stackgamma1, StackGamma stackgamma2,
											int3 dim_vol, float E, float size_voxel) {
	unsigned int id = __umul24(blockIdx.x, blockDim.x) + threadIdx.x;

	if (id < stackgamma1.size) {
		float jump = (float)(dim_vol.y * dim_vol.x);
		float ind, x, y, z;
		
		float rnd = voxsrc_Brent_real(id, stackgamma1.table_x_brent, 0);
		//int pos = (int)(rnd * (float)nb_act);
		int pos = 0;
		while (tex1Dfetch(tex_act_val, pos) < rnd) {++pos;};
		
		// get the voxel position (x, y, z)
		ind = (float)(tex1Dfetch(tex_act_ind, pos));
		z = floor(ind / jump);
		ind -= (z * jump);
		y = floor(ind / (float)(dim_vol.x));
		x = ind - y*dim_vol.x;

		// random position inside the voxel
		x += voxsrc_Brent_real(id, stackgamma1.table_x_brent, 0);
		y += voxsrc_Brent_real(id, stackgamma1.table_x_brent, 0);
		z += voxsrc_Brent_real(id, stackgamma1.table_x_brent, 0);

		// must be in mm
		x *= size_voxel;
		y *= size_voxel;
		z *= size_voxel;

		// random orientation
		float phi   = voxsrc_Brent_real(id, stackgamma1.table_x_brent, 0);
		float theta = voxsrc_Brent_real(id, stackgamma1.table_x_brent, 0);
		phi   = twopi * phi;
		theta = acosf(1.0f - 2.0f*theta);
		
		// convert to cartesian
		float dx = __cosf(phi)*__sinf(theta);
		float dy = __sinf(phi)*__sinf(theta);
		float dz = __cosf(theta);

		// first gamma
		stackgamma1.dx[id] = dx;
		stackgamma1.dy[id] = dy;
		stackgamma1.dz[id] = dz;
		stackgamma1.E[id] = E;
		stackgamma1.px[id] = x;
		stackgamma1.py[id] = y;
		stackgamma1.pz[id] = z;
		stackgamma1.t[id] = 0.0f;
		stackgamma1.live[id] = 1;
		stackgamma1.endsimu[id] = 0;
		stackgamma1.interaction[id] = 0;
		stackgamma1.ct_cpt[id] = 0;
		stackgamma1.ct_pe[id] = 0;
		stackgamma1.ct_ray[id] = 0;
		// second gamma
		stackgamma2.dx[id] = -dx;
		stackgamma2.dy[id] = -dy;
		stackgamma2.dz[id] = -dz;
		stackgamma2.E[id] = E;
		stackgamma2.px[id] = x;
		stackgamma2.py[id] = y;
		stackgamma2.pz[id] = z;
		stackgamma2.t[id] = 0.0f;
		stackgamma2.live[id] = 1;
		stackgamma2.endsimu[id] = 0;
		stackgamma2.interaction[id] = 0;
		stackgamma2.ct_cpt[id] = 0;
		stackgamma2.ct_pe[id] = 0;
		stackgamma2.ct_ray[id] = 0;
	}
}

/***********************************************************
 * Tracking kernel
 ***********************************************************/

// Regular tracking navigator
#define PHOTON_PHOTOELECTRIC 1
#define PHOTON_COMPTON 2
#define PHOTON_BOUNDARY_VOXEL 3
__global__ void kernel_voxsrc_regular_navigator(int3 dimvol, StackGamma stackgamma, float voxsize, int *gamma_sim_d) {
    
    unsigned int id = __umul24(blockIdx.x, blockDim.x) + threadIdx.x;
    
    if (id >= stackgamma.size) return;
    if (stackgamma.endsimu[id]) return;
    
    // Read position
    float3 position; // mm
    position.x = stackgamma.px[id];
    position.y = stackgamma.py[id];
    position.z = stackgamma.pz[id];
    
    // Defined index phantom
    int4 index_phantom;
    int jump = dimvol.x * dimvol.y;
    float ivoxsize = __fdividef(1.0f, voxsize);
    index_phantom.x = int(position.x * ivoxsize);
    index_phantom.y = int(position.y * ivoxsize);
    index_phantom.z = int(position.z * ivoxsize);    
    index_phantom.w = index_phantom.z * jump
                    + index_phantom.y * dimvol.x
                    + index_phantom.x; // linear index
    
    // Read direction
    float3 direction;
    direction.x = stackgamma.dx[id];
    direction.y = stackgamma.dy[id];
    direction.z = stackgamma.dz[id];
    
    // Get energy
    float energy = stackgamma.E[id];
    
    // Get material
    unsigned short int material = tex1Dfetch(tex_phantom, index_phantom.w);
    
    //// Find next discrete interaction ///////////////////////////////////////
    
    // Find next discrete interaction and next discrete intraction distance
    float next_interaction_distance =  FLT_MAX;
    unsigned char next_discrete_process = 0;
    float interaction_distance;
    float cross_section;
    
    // PhotoElectric
    cross_section = voxsrc_PhotoElec_CS_Standard(material, energy);
    interaction_distance = __fdividef(-__logf(voxsrc_Brent_real(id, stackgamma.table_x_brent, 0)), cross_section);
    
    if (interaction_distance < next_interaction_distance) {
        next_interaction_distance = interaction_distance;
        next_discrete_process = PHOTON_PHOTOELECTRIC;
    }
    
    // Compton
    cross_section = voxsrc_Compton_CS_Standard(material, energy);
    interaction_distance = __fdividef(-__logf(voxsrc_Brent_real(id, stackgamma.table_x_brent, 0)), cross_section);
    
    if (interaction_distance < next_interaction_distance) {
        next_interaction_distance = interaction_distance;
        next_discrete_process = PHOTON_COMPTON;
    }
    
    // Distance to the next voxel boundary (raycasting)
    interaction_distance = voxsrc_get_boundary_voxel_by_raycasting(index_phantom, position, direction, make_float3(voxsize, voxsize, voxsize));
    if (interaction_distance < next_interaction_distance) {
        next_interaction_distance = interaction_distance;
        next_discrete_process = PHOTON_BOUNDARY_VOXEL;
    }
    
    //// Move particle //////////////////////////////////////////////////////
    
    position.x += direction.x * next_interaction_distance;
    position.y += direction.y * next_interaction_distance;
    position.z += direction.z * next_interaction_distance;
    // Dirty part FIXME
    //   apply "magnetic grid" on the particle position due to aproximation
    //   from the GPU (on the next_interaction_distance).
    float eps = 1.0e-6f; // 1 um
    float res_min, res_max, grid_pos_min, grid_pos_max;
    index_phantom.x = int(position.x * ivoxsize);
    index_phantom.y = int(position.y * ivoxsize);
    index_phantom.z = int(position.z * ivoxsize);
    // on x
    grid_pos_min = index_phantom.x * dimvol.x;
    grid_pos_max = (index_phantom.x+1) * dimvol.x;
    res_min = position.x - grid_pos_min;
    res_max = position.x - grid_pos_max;
    if (res_min < eps) {position.x = grid_pos_min;}
    if (res_max > eps) {position.x = grid_pos_max;}
    // on y
    grid_pos_min = index_phantom.y * dimvol.y;
    grid_pos_max = (index_phantom.y+1) * dimvol.y;
    res_min = position.y - grid_pos_min;
    res_max = position.y - grid_pos_max;
    if (res_min < eps) {position.y = grid_pos_min;}
    if (res_max > eps) {position.y = grid_pos_max;}
    // on z
    grid_pos_min = index_phantom.z * dimvol.z;
    grid_pos_max = (index_phantom.z+1) * dimvol.z;
    res_min = position.z - grid_pos_min;
    res_max = position.z - grid_pos_max;
    if (res_min < eps) {position.z = grid_pos_min;}
    if (res_max > eps) {position.z = grid_pos_max;}
    
    stackgamma.px[id] = position.x;
    stackgamma.py[id] = position.y;
    stackgamma.pz[id] = position.z;

    // Stop simulation if out of phantom or no more energy
    if ( position.x <= 0 || position.x >= dimvol.x*voxsize
        || position.y <= 0 || position.y >= dimvol.y*voxsize
        || position.z <= 0 || position.z >= dimvol.z*voxsize) {
        stackgamma.endsimu[id] = 1;                     // stop the simulation
        atomicAdd(gamma_sim_d, 1);                       // count simulated primaries
        return;
    }
    
    //// Resolve discrete processe //////////////////////////////////////////
    
    // Resolve discrete processes
    if (next_discrete_process == PHOTON_PHOTOELECTRIC) {
        stackgamma.live[id] = 0;    // kill the particle.
        stackgamma.endsimu[id] = 1; // stop the simulation
        atomicAdd(gamma_sim_d, 1);
        return;
    }
    
    if (next_discrete_process == PHOTON_COMPTON) {
        float3 newdir = voxsrc_Compton_scatter_Standard(stackgamma, id, gamma_sim_d);
		direction = deflect_particle(direction, newdir);
		stackgamma.dx[id] = direction.x;
		stackgamma.dy[id] = direction.y;
		stackgamma.dz[id] = direction.z;
        return;
    }
    
}
#undef PHOTON_PHOTOELECTRIC 1
#undef PHOTON_COMPTON 2
#undef PHOTON_BOUNDARY_VOXEL 3


// Fictitious tracking (or delta-tracking)
__global__ void kernel_voxsrc_woodcock_Standard(int3 dimvol, StackGamma stackgamma, float dimvox, int most_att_mat, int* gamma_sim_d) {
	unsigned int id = __umul24(blockIdx.x, blockDim.x) + threadIdx.x;
	int jump = dimvol.x * dimvol.y;
	float3 p, p0, delta, dimvolmm, dp;
	float3 cur_CS;
	int3 vox;
	float path, rec_mu_maj, E, sum_CS, t;
	int i=0;
	unsigned short int mat;
	dimvolmm.x = dimvol.x * dimvox;
	dimvolmm.y = dimvol.y * dimvox;
	dimvolmm.z = dimvol.z * dimvox;
	dimvox = __fdividef(1.0f, dimvox);

	if (id < stackgamma.size && !stackgamma.endsimu[id]) {
		p0.x = stackgamma.px[id];
		p0.y = stackgamma.py[id];
		p0.z = stackgamma.pz[id];
		p.x = p0.x;
		p.y = p0.y;
		p.z = p0.z;
		delta.x = stackgamma.dx[id];
		delta.y = stackgamma.dy[id];
		delta.z = stackgamma.dz[id];
		E = stackgamma.E[id];
		t = stackgamma.t[id];
		

		// Most attenuate material
		cur_CS.x = voxsrc_PhotoElec_CS_Standard(most_att_mat, E);
		cur_CS.y = voxsrc_Compton_CS_Standard(most_att_mat, E);
		rec_mu_maj = __fdividef(1.0f, cur_CS.x + cur_CS.y);

		// init mem share
		__shared__ float CS[256][15];
		while (i<15) {CS[threadIdx.x][i] = 0.0f; ++i;}
			
		while (1) {
			// get mean path from the most attenuate material (RibBone)
			path = -__logf(voxsrc_Brent_real(id, stackgamma.table_x_brent, 0)) * rec_mu_maj; // mm
			
			// fly along the path
			p.x = p.x + delta.x * path;
			p.y = p.y + delta.y * path;
			p.z = p.z + delta.z * path;

			// still inside the phantom? if not
			if (p.x < 0 || p.y < 0 || p.z < 0
				|| p.x >= dimvolmm.x || p.y >= dimvolmm.y || p.z >= dimvolmm.z) {
				stackgamma.endsimu[id] = 1; // stop simulation for this one
				stackgamma.interaction[id] = 0;
                atomicAdd(gamma_sim_d, 1);
				
				/*    
                float dimvoxbis = __fdividef(1.0f, dimvox);
				float r=dimvoxbis*0.1;
				
				while(p.x < -r || p.y < -r || p.z < -r
				|| p.x >= dimvolmm.x+r || p.y >= dimvolmm.y+r || p.z >= dimvolmm.z+r){
					p.x = p.x - delta.x * r;
					p.y = p.y - delta.y * r;
					p.z = p.z - delta.z * r;
				}*/
				
				dp.x = p0.x - p.x;
				dp.y = p0.y - p.y;
				dp.z = p0.z - p.z;
				
				t += (3.33564095198e-03f * sqrt(dp.x*dp.x + dp.y*dp.y + dp.z*dp.z));
				
				stackgamma.px[id] = p.x;
				stackgamma.py[id] = p.y;
				stackgamma.pz[id] = p.z;
				stackgamma.t[id] = t;

				return;
			}
		
			// which voxel?
			vox.x = int(p.x * dimvox);
			vox.y = int(p.y * dimvox);
			vox.z = int(p.z * dimvox);
			
			// get mat
			mat = tex1Dfetch(tex_phantom, vox.z*jump + vox.y*dimvol.x + vox.x);

			// Bib of sum_CS
			if (CS[threadIdx.x][mat] == 0.0f) {
				// get CS
				cur_CS.x = voxsrc_PhotoElec_CS_Standard(mat, E);
				cur_CS.y = voxsrc_Compton_CS_Standard(mat, E);
				sum_CS = cur_CS.x + cur_CS.y;
				CS[threadIdx.x][mat] = sum_CS;
			} else {
				sum_CS = CS[threadIdx.x][mat];
			}

			// Does the interaction is real?
			if (sum_CS * rec_mu_maj > voxsrc_Brent_real(id, stackgamma.table_x_brent, 0)) {break;}
		}

		dp.x = p0.x - p.x;
		dp.y = p0.y - p.y;
		dp.z = p0.z - p.z;
	
		t += (3.33564095198e-03f * sqrt(dp.x*dp.x + dp.y*dp.y + dp.z*dp.z));
		
		stackgamma.px[id] = p.x;
		stackgamma.py[id] = p.y;
		stackgamma.pz[id] = p.z;
		stackgamma.t[id] = t;
		
        cur_CS.x = voxsrc_PhotoElec_CS_Standard(mat, E);
        cur_CS.y = voxsrc_Compton_CS_Standard(mat, E);
        sum_CS = cur_CS.x + cur_CS.y;

	    if (__fdividef(cur_CS.x, sum_CS)>voxsrc_Brent_real(id, stackgamma.table_x_brent, 0)) {
            stackgamma.interaction[id] = 1;
        } else {
            stackgamma.interaction[id] = 2;
        }

    }
}

/***********************************************************
 * Interactions
 ***********************************************************/

// Kernel interactions
__global__ void kernel_voxsrc_interactions(StackGamma stackgamma, int3 dimvol, float dimvox, int* gamma_sim_d) {
	unsigned int id = __umul24(blockIdx.x, blockDim.x) + threadIdx.x;
	float3 dir;

	if (id < stackgamma.size && !stackgamma.endsimu[id]) {
		switch (stackgamma.interaction[id]) {
		case 0:
			// do nothing and release the thread (maybe the block if interactions are sorted)
			return;
		case 1:
			// PhotoElectric effect
			stackgamma.live[id] = 0;    // kill the particle.
			stackgamma.endsimu[id] = 1; // stop the simulation
			++stackgamma.ct_pe[id];
            atomicAdd(gamma_sim_d, 1);
			return;
		case 2:
			// Compton scattering
			++stackgamma.ct_cpt[id];
			// Model standard
			dir = voxsrc_Compton_scatter_Standard(stackgamma, id, gamma_sim_d);
			break;
		}

		//*************************************
		// Apply new direction to the particle 
		//
		float3 p = make_float3(stackgamma.dx[id], stackgamma.dy[id], stackgamma.dz[id]);
		p = deflect_particle(p, dir);
		stackgamma.dx[id] = p.x;
		stackgamma.dy[id] = p.y;
		stackgamma.dz[id] = p.z;
		
	}
}

/***********************************************************
 * Utils Host
 ***********************************************************/
// For PRNG Brent
#define UINT64 (sizeof(unsigned long)>>3)
#define UINT32 (1 - UINT64)
#define r      (4*UINT64 + 8*UINT32)
// Stack device allocation
void init_device_stackgamma(StackGamma &stackgamma, int stack_size) {
	stackgamma.size = stack_size;
	unsigned int mem_stackgamma_float = stack_size * sizeof(float);
	unsigned int mem_stackgamma_uint = stack_size * sizeof(unsigned int);
	unsigned int mem_stackgamma_char = stack_size * sizeof(char);
	unsigned int mem_brent;
	if (r == 4) {mem_brent = stack_size * 6 * sizeof(unsigned long);}
	else {mem_brent = stack_size * 10 * sizeof(unsigned long);}

	cudaMalloc((void**) &stackgamma.E, mem_stackgamma_float);
	cudaMalloc((void**) &stackgamma.dx, mem_stackgamma_float);
	cudaMalloc((void**) &stackgamma.dy, mem_stackgamma_float);
	cudaMalloc((void**) &stackgamma.dz, mem_stackgamma_float);
	cudaMalloc((void**) &stackgamma.px, mem_stackgamma_float);
	cudaMalloc((void**) &stackgamma.py, mem_stackgamma_float);
	cudaMalloc((void**) &stackgamma.pz, mem_stackgamma_float);
	cudaMalloc((void**) &stackgamma.t, mem_stackgamma_float);
	cudaMalloc((void**) &stackgamma.seed, mem_stackgamma_uint);
	cudaMalloc((void**) &stackgamma.table_x_brent, mem_brent);
	cudaMalloc((void**) &stackgamma.interaction, mem_stackgamma_char);
	cudaMalloc((void**) &stackgamma.live, mem_stackgamma_char);
	cudaMalloc((void**) &stackgamma.endsimu, mem_stackgamma_char);
	cudaMalloc((void**) &stackgamma.ct_cpt, mem_stackgamma_char);
	cudaMalloc((void**) &stackgamma.ct_pe, mem_stackgamma_char);
	cudaMalloc((void**) &stackgamma.ct_ray, mem_stackgamma_char);
	// set endsimu to one in order to force a reload of each stack
	char* tmpc = (char*)malloc(stack_size * sizeof(char));
	int n=0; while (n<stack_size) {tmpc[n] = 1; ++n;};
	cudaMemcpy(stackgamma.endsimu, tmpc, stack_size * sizeof(char), cudaMemcpyHostToDevice);
	free(tmpc);
}
#undef UINT64
#undef UINT32
#undef r

// Stack host allocation
void init_host_stackgamma(StackGamma &phasespace, int stack_size) {
	phasespace.size = stack_size;
	unsigned int mem_phasespace_float = stack_size * sizeof(float);
	unsigned int mem_phasespace_uint = stack_size * sizeof(unsigned int);
	unsigned int mem_phasespace_char = stack_size * sizeof(char);
	phasespace.E = (float*)malloc(mem_phasespace_float);
	phasespace.dx = (float*)malloc(mem_phasespace_float);
	phasespace.dy = (float*)malloc(mem_phasespace_float);
	phasespace.dz = (float*)malloc(mem_phasespace_float);
	phasespace.px = (float*)malloc(mem_phasespace_float);
	phasespace.py = (float*)malloc(mem_phasespace_float);
	phasespace.pz = (float*)malloc(mem_phasespace_float);
	phasespace.t = (float*)malloc(mem_phasespace_float);
	phasespace.seed = (unsigned int*)malloc(mem_phasespace_uint);
	phasespace.interaction = (unsigned char*)malloc(mem_phasespace_char);
	phasespace.live = (unsigned char*)malloc(mem_phasespace_char);
	phasespace.endsimu = (unsigned char*)malloc(mem_phasespace_char);
	phasespace.ct_cpt = (unsigned char*)malloc(mem_phasespace_char);
	phasespace.ct_pe = (unsigned char*)malloc(mem_phasespace_char);
	phasespace.ct_ray = (unsigned char*)malloc(mem_phasespace_char);
	// set endsimu to one in order to force a reload of each stack
	int n=0; while (n<stack_size) {phasespace.endsimu[n] = 1; ++n;};

}

// Copy stack from device to host
void copy_device_to_host_stackgamma(StackGamma &stackgamma, StackGamma &phasespace) {
	int stack_size = stackgamma.size;
	unsigned int mem_stackgamma_float = stack_size * sizeof(float);
	unsigned int mem_stackgamma_char = stack_size * sizeof(char);
	cudaMemcpy(phasespace.E, stackgamma.E, mem_stackgamma_float, cudaMemcpyDeviceToHost);
	cudaMemcpy(phasespace.dx, stackgamma.dx, mem_stackgamma_float, cudaMemcpyDeviceToHost);
	cudaMemcpy(phasespace.dy, stackgamma.dy, mem_stackgamma_float, cudaMemcpyDeviceToHost);
	cudaMemcpy(phasespace.dz, stackgamma.dz, mem_stackgamma_float, cudaMemcpyDeviceToHost);
	cudaMemcpy(phasespace.px, stackgamma.px, mem_stackgamma_float, cudaMemcpyDeviceToHost);
	cudaMemcpy(phasespace.py, stackgamma.py, mem_stackgamma_float, cudaMemcpyDeviceToHost);
	cudaMemcpy(phasespace.pz, stackgamma.pz, mem_stackgamma_float, cudaMemcpyDeviceToHost);
	cudaMemcpy(phasespace.t, stackgamma.t, mem_stackgamma_float, cudaMemcpyDeviceToHost);
	cudaMemcpy(phasespace.endsimu, stackgamma.endsimu, mem_stackgamma_char, cudaMemcpyDeviceToHost);
	cudaMemcpy(phasespace.live, stackgamma.live, mem_stackgamma_char, cudaMemcpyDeviceToHost);
}

// free device mem
void free_device_stackgamma(StackGamma &stackgamma) {
	cudaFree(stackgamma.E);
	cudaFree(stackgamma.dx);
	cudaFree(stackgamma.dy);
	cudaFree(stackgamma.dz);
	cudaFree(stackgamma.px);
	cudaFree(stackgamma.py);
	cudaFree(stackgamma.pz);
	cudaFree(stackgamma.t);
	cudaFree(stackgamma.interaction);
	cudaFree(stackgamma.live);
	cudaFree(stackgamma.endsimu);
	cudaFree(stackgamma.seed);
	cudaFree(stackgamma.ct_cpt);
	cudaFree(stackgamma.ct_pe);
	cudaFree(stackgamma.ct_ray);
	cudaFree(stackgamma.table_x_brent);
}

// free host mem
void free_host_stackgamma(StackGamma &phasespace) {
	free(phasespace.E);
	free(phasespace.dx);
	free(phasespace.dy);
	free(phasespace.dz);
	free(phasespace.px);
	free(phasespace.py);
	free(phasespace.pz);
	free(phasespace.t);
	free(phasespace.interaction);
	free(phasespace.live);
	free(phasespace.endsimu);
	free(phasespace.seed);
	free(phasespace.ct_cpt);
	free(phasespace.ct_pe);
	free(phasespace.ct_ray);
}

// Count nb of partice already simulated
void get_nb_particles_simulated(StackGamma &stackgamma1, StackGamma &stackgamma2,
								StackGamma &phasespace1, StackGamma &phasespace2,
								int* gamma_sim) {
								 
	int stack_size = phasespace1.size;
	copy_device_to_host_stackgamma(stackgamma1, phasespace1);
	copy_device_to_host_stackgamma(stackgamma2, phasespace2);
	int	i = 0;
	int end1, end2;
	*gamma_sim = 0;
	while (i < stack_size) {
		end1 = (int)phasespace1.endsimu[i];
		end2 = (int)phasespace2.endsimu[i];

		if (end1) {++(*gamma_sim);};
		if (end2) {++(*gamma_sim);};
		++i;
	} // i
}

// FIXME this function is the same than the actor_fun.cu and not used
// Load phantom in the tex mem
/*
void load_phantom_in_tex(const char* filename, int3 dim_phantom) {
	int nb = dim_phantom.z * dim_phantom.y * dim_phantom.x;
	unsigned int mem_phantom = nb * sizeof(unsigned short int);
	unsigned short int* phantom = (unsigned short int*)malloc(mem_phantom);
	// Read data
	FILE * pfile = fopen(filename, "rb");
	fread(phantom, sizeof(unsigned short int), nb, pfile);
	fclose(pfile);
	// Load phantom to texture
	unsigned short int* dphantom;
	cudaMalloc((void**) &dphantom, mem_phantom);
	cudaMemcpy(dphantom, phantom, mem_phantom, cudaMemcpyHostToDevice);
	cudaBindTexture(NULL, tex_phantom, dphantom, mem_phantom);
	free(phantom);
} */

// Load activities in the tex mem
void load_activities_in_tex(const char* filename_act, const char* filename_ind, int nb) {
	FILE* pfile_act = fopen(filename_act, "rb");
	unsigned int mem_act_f = nb * sizeof(float);
	unsigned int mem_act_i = nb * sizeof(unsigned int);
	// load activities values in the tex mem
	float* activities = (float*)malloc(mem_act_f);
	fread(activities, sizeof(float), nb, pfile_act);
	fclose(pfile_act);
	float* dactivities;
	cudaMalloc((void**) &dactivities, mem_act_f);
	cudaMemcpy(dactivities, activities, mem_act_f, cudaMemcpyHostToDevice);
	cudaBindTexture(NULL, tex_act_val, dactivities, mem_act_f);
	free(activities);
	// load activities indices in the tex mem
	unsigned int* index = (unsigned int*)malloc(mem_act_i);
	FILE* pfile_ind = fopen(filename_ind, "rb");
	fread(index, sizeof(unsigned int), nb, pfile_ind);
	fclose(pfile_ind);
	unsigned int* dindex;
	cudaMalloc((void**) &dindex, mem_act_i);
	cudaMemcpy(dindex, index, mem_act_i, cudaMemcpyHostToDevice);
	cudaBindTexture(NULL, tex_act_ind, dindex, mem_act_i);
	free(index);
}

// Get the number of active voxel in the voxelized source
int get_nb_active_voxel(const char* filename_act) {
	FILE* pfile_act = fopen(filename_act, "rb");
	fseek(pfile_act, 0, SEEK_END);
	int nb = ftell(pfile_act);
	nb /= 4;
	fclose(pfile_act);
	return nb;
}

// back raytrace and check the collision
void back_raytrace_phasespace(StackGamma &stack, int nbgamma, int3 dim_phantom, float size_voxel) {

	float xmin, xmax, ymin, ymax, zmin, zmax;
	xmin = 0;
	xmax = dim_phantom.x * size_voxel;
	ymin = 0;
	ymax = dim_phantom.y * size_voxel;
	zmin = 0;
	zmax = dim_phantom.z * size_voxel;

	int i = 0;
	float eps = 0.1f;
	float dx, dy, dz;
	double dof, tof;

	float xi1, yi1, zi1;
	float xd, yd, zd;
	float tmin, tmax, tymin, tymax, tzmin, tzmax;
	float xdi, ydi, zdi;
	float buf, newz;
	while (i < nbgamma) {
        if (!stack.live[i]) {++i; continue;}

		xi1 = stack.px[i];
		yi1 = stack.py[i];
		zi1 = stack.pz[i];
		xd = -stack.dx[i];
		yd = -stack.dy[i];
		zd = -stack.dz[i];

		tmin = -1e9f;
		tmax = 1e9f;
		
		// on x
		if (xd != 0.0f) {
			xdi = 1.0f / xd;
			tmin = (xmin - xi1) * xdi;
			tmax = (xmax - xi1) * xdi;
			if (tmin > tmax) {
				buf = tmin;
				tmin = tmax;
				tmax = buf;
			}
		}
		// on y
		if (yd != 0.0f) {
			ydi = 1.0f / yd;
			tymin = (ymin - yi1) * ydi;
			tymax = (ymax - yi1) * ydi;
			if (tymin > tymax) {
				buf = tymin;
				tymin = tymax;
				tymax = buf;
			}
			if (tymin > tmin) {tmin = tymin;}
			if (tymax < tmax) {tmax = tymax;}
		}
		// on z
		if (zd != 0.0f) {
			zdi = 1.0f / zd;
			tzmin = (zmin - zi1) * zdi;
			tzmax = (zmax - zi1) * zdi;
			if (tzmin > tzmax) {
				buf = tzmin;
				tzmin = tzmax;
				tzmax = buf;
			}
			if (tzmin > tmin) {tmin = tzmin;}
			if (tzmax < tmax) {tmax = tzmax;}
		}
		// compute points
		dz = zd * tmin;
        dx = xd * tmin;
        dy = yd * tmin;
        stack.px[i] = xi1 + dx;
        stack.py[i] = yi1 + dy;
        stack.pz[i] = zi1 + dz;

        dof = sqrt(dx*dx + dy*dy + dz*dz);
        tof = 3.33564095198e-03f * dof;
        stack.t[i] = stack.t[i] - tof;
			
		++i;
	} // while gamma

}

// Get time
double voxsrc_time() {
    timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1000000.0;
}

















