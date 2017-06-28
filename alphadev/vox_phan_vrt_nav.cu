// GGEMS Copyright (C) 2017

/*!
 * \file vox_phan_vrt_nav.cu
 * \brief
 * \author J. Bert <bert.jul@gmail.com>
 * \version 0.2
 * \date 23/03/2016
 *
 * v0.2: JB - Change all structs and remove CPU exec
 *
 */

#ifndef VOX_PHAN_VRT_NAV_CU
#define VOX_PHAN_VRT_NAV_CU

#include "vox_phan_vrt_nav.cuh"
#include "image_io.cuh"

////// HOST-DEVICE GPU Codes ////////////////////////////////////////////

__host__ __device__ void VPVRTN::track_to_out_analog(ParticlesData *particles,
                                                      const VoxVolumeData<ui16> *vol,
                                                      const MaterialsData *materials,
                                                      const PhotonCrossSectionData *photon_CS_table,
                                                      const GlobalSimulationParametersData *parameters,
                                                      DoseData *dosi,
                                                      ui32 part_id )
{
    // Read position
    f32xyz pos;
    pos.x = particles->px[part_id];
    pos.y = particles->py[part_id];
    pos.z = particles->pz[part_id];

    // Read direction
    f32xyz dir;
    dir.x = particles->dx[part_id];
    dir.y = particles->dy[part_id];
    dir.z = particles->dz[part_id];

    // Defined index phantom
    f32xyz ivoxsize;
    ivoxsize.x = 1.0 / vol->spacing_x;
    ivoxsize.y = 1.0 / vol->spacing_y;
    ivoxsize.z = 1.0 / vol->spacing_z;
    ui32xyzw index_phantom;
    index_phantom.x = ui32 ( ( pos.x + vol->off_x ) * ivoxsize.x );
    index_phantom.y = ui32 ( ( pos.y + vol->off_y ) * ivoxsize.y );
    index_phantom.z = ui32 ( ( pos.z + vol->off_z ) * ivoxsize.z );

    index_phantom.w = index_phantom.z*vol->nb_vox_x*vol->nb_vox_y
            + index_phantom.y*vol->nb_vox_x
            + index_phantom.x; // linear index

    // Get the material that compose this volume
    ui16 mat_id = vol->values[ index_phantom.w ];

    // Vars
    f32 next_interaction_distance;
    ui8 next_discrete_process;

    //// Find next discrete interaction ///////////////////////////////////////

    photon_get_next_interaction( particles, parameters, photon_CS_table, mat_id, part_id );

    next_interaction_distance = particles->next_interaction_distance[part_id];
    next_discrete_process = particles->next_discrete_process[part_id];

    //// Get the next distance boundary volume /////////////////////////////////

    f32 vox_xmin = index_phantom.x*vol->spacing_x - vol->off_x;
    f32 vox_ymin = index_phantom.y*vol->spacing_y - vol->off_y;
    f32 vox_zmin = index_phantom.z*vol->spacing_z - vol->off_z;
    f32 vox_xmax = vox_xmin + vol->spacing_x;
    f32 vox_ymax = vox_ymin + vol->spacing_y;
    f32 vox_zmax = vox_zmin + vol->spacing_z;

    // get a safety position for the particle within this voxel (sometime a particle can be right between two voxels)
    // TODO: In theory this have to be applied just at the entry of the particle within the volume
    //       in order to avoid particle entry between voxels. Then, computing improvement can be made
    //       by calling this function only once, just for the particle step=0.    - JB
    pos = transport_get_safety_inside_AABB( pos, vox_xmin, vox_xmax,
                                            vox_ymin, vox_ymax, vox_zmin, vox_zmax, parameters->geom_tolerance );

    f32 boundary_distance = hit_ray_AABB( pos, dir, vox_xmin, vox_xmax,
                                          vox_ymin, vox_ymax, vox_zmin, vox_zmax );

    if ( boundary_distance <= next_interaction_distance )
    {
        next_interaction_distance = boundary_distance + parameters->geom_tolerance; // Overshoot
        next_discrete_process = GEOMETRY_BOUNDARY;
    }

    //// Move particle //////////////////////////////////////////////////////

    // get the new position
    pos = fxyz_add( pos, fxyz_scale( dir, next_interaction_distance ) );

    // get safety position (outside the current voxel)
    pos = transport_get_safety_outside_AABB( pos, vox_xmin, vox_xmax,
                                             vox_ymin, vox_ymax, vox_zmin, vox_zmax, parameters->geom_tolerance );

    // Stop simulation if out of the phantom
    if ( !test_point_AABB_with_tolerance ( pos, vol->xmin, vol->xmax, vol->ymin, vol->ymax,
                                           vol->zmin, vol->zmax, parameters->geom_tolerance ) )
    {
        particles->status[part_id] = PARTICLE_FREEZE;
        return;
    }

    //// Apply discrete process //////////////////////////////////////////////////

    // Resolve process
    if ( next_discrete_process != GEOMETRY_BOUNDARY )
    {
        // Resolve discrete process
        SecParticle electron = photon_resolve_discrete_process ( particles, parameters, photon_CS_table,
                                                                 materials, mat_id, part_id );
        /// Energy cut /////////////

        // If gamma particle not enough energy (Energy cut)
        if ( particles->E[ part_id ] <= materials->photon_energy_cut[ mat_id ] )
        {
            // Kill without mercy
            particles->status[ part_id ] = PARTICLE_DEAD;
        }

        /// Drop energy ////////////

        // If gamma particle is dead (PE, Compton or energy cut)
        if ( particles->status[ part_id ] == PARTICLE_DEAD &&  particles->E[ part_id ] != 0.0f )
        {
            dose_record_standard( dosi, particles->E[ part_id ], pos.x,
                                  pos.y, pos.z );
        }

        // If electron particle has energy
        if ( electron.E != 0.0f )
        {
            dose_record_standard( dosi, electron.E, pos.x,
                                  pos.y, pos.z );
        }
    } // geom boundary

    // store the new position
    particles->px[part_id] = pos.x;
    particles->py[part_id] = pos.y;
    particles->pz[part_id] = pos.z;

}

__host__ __device__ void VPVRTN::track_to_out_tle( ParticlesData *particles,
                                                   const VoxVolumeData<ui16> *vol,
                                                   const MaterialsData *materials,
                                                   const PhotonCrossSectionData *photon_CS_table,
                                                   const GlobalSimulationParametersData *parameters,
                                                   DoseData *dosi,
                                                   const VRT_Mu_MuEn_Data *mu_table,
                                                   ui32 part_id )
{
    // Read position
    f32xyz pos;
    pos.x = particles->px[part_id];
    pos.y = particles->py[part_id];
    pos.z = particles->pz[part_id];

    // Read direction
    f32xyz dir;
    dir.x = particles->dx[part_id];
    dir.y = particles->dy[part_id];
    dir.z = particles->dz[part_id];

    // Defined index phantom
    f32xyz ivoxsize;
    ivoxsize.x = 1.0 / vol->spacing_x;
    ivoxsize.y = 1.0 / vol->spacing_y;
    ivoxsize.z = 1.0 / vol->spacing_z;
    ui32xyzw index_phantom;
    index_phantom.x = ui32 ( ( pos.x + vol->off_x ) * ivoxsize.x );
    index_phantom.y = ui32 ( ( pos.y + vol->off_y ) * ivoxsize.y );
    index_phantom.z = ui32 ( ( pos.z + vol->off_z ) * ivoxsize.z );

    index_phantom.w = index_phantom.z*vol->nb_vox_x*vol->nb_vox_y
            + index_phantom.y*vol->nb_vox_x
            + index_phantom.x; // linear index

    // Get the material that compose this volume
    ui16 mat_id = vol->values[ index_phantom.w ];

    // Vars
    f32 next_interaction_distance;
    ui8 next_discrete_process;

    //// Find next discrete interaction ///////////////////////////////////////

    photon_get_next_interaction( particles, parameters, photon_CS_table, mat_id, part_id );

    next_interaction_distance = particles->next_interaction_distance[part_id];
    next_discrete_process = particles->next_discrete_process[part_id];

    //// Get the next distance boundary volume /////////////////////////////////

    f32 vox_xmin = index_phantom.x*vol->spacing_x - vol->off_x;
    f32 vox_ymin = index_phantom.y*vol->spacing_y - vol->off_y;
    f32 vox_zmin = index_phantom.z*vol->spacing_z - vol->off_z;
    f32 vox_xmax = vox_xmin + vol->spacing_x;
    f32 vox_ymax = vox_ymin + vol->spacing_y;
    f32 vox_zmax = vox_zmin + vol->spacing_z;

    // get a safety position for the particle within this voxel (sometime a particle can be right between two voxels)
    // TODO: In theory this have to be applied just at the entry of the particle within the volume
    //       in order to avoid particle entry between voxels. Then, computing improvement can be made
    //       by calling this function only once, just for the particle step=0.    - JB
    pos = transport_get_safety_inside_AABB( pos, vox_xmin, vox_xmax,
                                            vox_ymin, vox_ymax, vox_zmin, vox_zmax, parameters->geom_tolerance );

    f32 boundary_distance = hit_ray_AABB( pos, dir, vox_xmin, vox_xmax,
                                          vox_ymin, vox_ymax, vox_zmin, vox_zmax );

    if ( boundary_distance <= next_interaction_distance )
    {
        next_interaction_distance = boundary_distance + parameters->geom_tolerance; // Overshoot
        next_discrete_process = GEOMETRY_BOUNDARY;
    }

    //// Move particle //////////////////////////////////////////////////////

    // get the new position
    pos = fxyz_add( pos, fxyz_scale( dir, next_interaction_distance ) );

    // get safety position (outside the current voxel)
    pos = transport_get_safety_outside_AABB( pos, vox_xmin, vox_xmax,
                                             vox_ymin, vox_ymax, vox_zmin, vox_zmax, parameters->geom_tolerance );

    // Stop simulation if out of the phantom
    if ( !test_point_AABB_with_tolerance ( pos, vol->xmin, vol->xmax, vol->ymin, vol->ymax,
                                           vol->zmin, vol->zmax, parameters->geom_tolerance ) )
    {
        particles->status[part_id] = PARTICLE_FREEZE;
        return;
    }

    //// Apply discrete process //////////////////////////////////////////////////

    f32 energy = particles->E[ part_id ];

    if ( next_discrete_process != GEOMETRY_BOUNDARY )
    {
        // Resolve discrete process
        SecParticle electron = photon_resolve_discrete_process ( particles, parameters, photon_CS_table,
                                                                 materials, mat_id, part_id );
    } // discrete process

    /// Drop energy ////////////

    // Get the mu_en for the current E
    ui32 E_index = binary_search ( energy, mu_table->E_bins, mu_table->nb_bins );

    f32 mu_en;

    if ( E_index == 0 )
    {
        mu_en = mu_table->mu_en[ mat_id*mu_table->nb_bins ];
    }
    else
    {
        mu_en = linear_interpolation( mu_table->E_bins[E_index-1],  mu_table->mu_en[mat_id*mu_table->nb_bins + E_index-1],
                mu_table->E_bins[E_index],    mu_table->mu_en[mat_id*mu_table->nb_bins + E_index],
                energy );
    }

    //                             record to the old position (current voxel)
    dose_record_TLE( dosi, energy, particles->px[ part_id ], particles->py[ part_id ],
                     particles->pz[ part_id ], next_interaction_distance,  mu_en );

    /// Energy cut /////////////

    // If gamma particle not enough energy (Energy cut)
    if ( particles->E[ part_id ] <= materials->photon_energy_cut[ mat_id ] )
    {
        // Kill without mercy
        particles->status[ part_id ] = PARTICLE_DEAD;
    }

    // store the new position
    particles->px[part_id] = pos.x;
    particles->py[part_id] = pos.y;
    particles->pz[part_id] = pos.z;

}


/// Experimental ///////////////////////////////////////////////

__host__ __device__ void VPVRTN::track_to_out_woodcock(ParticlesData *particles,
                                                        const VoxVolumeData<ui16> *vol,
                                                        const MaterialsData *materials,
                                                        const PhotonCrossSectionData *photon_CS_table,
                                                        const GlobalSimulationParametersData *parameters,
                                                        DoseData *dosi,
                                                        f32* mumax_table,
                                                        ui32 part_id)
{
    // Read position
    f32xyz pos;
    pos.x = particles->px[part_id];
    pos.y = particles->py[part_id];
    pos.z = particles->pz[part_id];

    // Defined index phantom
    f32xyz ivoxsize;
    ivoxsize.x = 1.0 / vol->spacing_x;
    ivoxsize.y = 1.0 / vol->spacing_y;
    ivoxsize.z = 1.0 / vol->spacing_z;
    ui32xyzw index_phantom;
    index_phantom.x = ui32( ( pos.x + vol->off_x ) * ivoxsize.x );
    index_phantom.y = ui32( ( pos.y + vol->off_y ) * ivoxsize.y );
    index_phantom.z = ui32( ( pos.z + vol->off_z ) * ivoxsize.z );

    index_phantom.w = index_phantom.z*vol->nb_vox_x*vol->nb_vox_y
            + index_phantom.y*vol->nb_vox_x
            + index_phantom.x; // linear index

    // Read direction
    f32xyz dir;
    dir.x = particles->dx[part_id];
    dir.y = particles->dy[part_id];
    dir.z = particles->dz[part_id];

    // Vars
    f32 next_interaction_distance;
    f32 interaction_distance;

    //// Find next discrete interaction ///////////////////////////////////////

    // Search the energy index to read CS
    f32 energy = particles->E[part_id];
    ui32 E_index = binary_search( energy, photon_CS_table->E_bins,
                                  photon_CS_table->nb_bins );

    // Get index CS table (considering mat id)
    f32 CS_max = get_CS_from_table( photon_CS_table->E_bins, mumax_table,
                                    energy, E_index, E_index );

    // Woodcock tracking
    next_interaction_distance = -log( prng_uniform( particles, part_id ) ) * CS_max;
    interaction_distance  = next_interaction_distance;

    //// Move particle //////////////////////////////////////////////////////

    // get the new position
    pos = fxyz_add ( pos, fxyz_scale ( dir, next_interaction_distance ) );

    // Stop simulation if out of the phantom
    if ( !test_point_AABB_with_tolerance( pos, vol->xmin, vol->xmax, vol->ymin, vol->ymax,
                                          vol->zmin, vol->zmax, parameters->geom_tolerance ) )
    {
        particles->status[part_id] = PARTICLE_FREEZE;
        return;
    }

    // store the new position
    particles->px[part_id] = pos.x;
    particles->py[part_id] = pos.y;
    particles->pz[part_id] = pos.z;

    //// Real or fictif process /////////////////////////////////////////////////

    // Defined index phantom
    /*f32xyz ivoxsize;
    ivoxsize.x = 1.0 / vol->spacing_x;
    ivoxsize.y = 1.0 / vol->spacing_y;
    ivoxsize.z = 1.0 / vol->spacing_z;
    ui32xyzw index_phantom;*/
    index_phantom.x = ui32( ( pos.x + vol->off_x ) * ivoxsize.x );
    index_phantom.y = ui32( ( pos.y + vol->off_y ) * ivoxsize.y );
    index_phantom.z = ui32( ( pos.z + vol->off_z ) * ivoxsize.z );

    index_phantom.w = index_phantom.z*vol->nb_vox_x*vol->nb_vox_y
            + index_phantom.y*vol->nb_vox_x
            + index_phantom.x; // linear index

    // Get the material that compose this volume
    ui16 mat_id = vol->values[ index_phantom.w ];

    // Get index CS table (considering mat id)
    ui32 CS_index = mat_id*photon_CS_table->nb_bins + E_index;
    f32 sum_CS = 0.0;
    f32 CS_PE = 0.0;
    f32 CS_CPT = 0.0;
    f32 CS_RAY = 0.0;
    next_interaction_distance = F32_MAX;
    ui8 next_discrete_process = 0;

    if ( parameters->physics_list[PHOTON_PHOTOELECTRIC] )
    {
        CS_PE = get_CS_from_table( photon_CS_table->E_bins, photon_CS_table->Photoelectric_Std_CS,
                                   energy, E_index, CS_index );
        sum_CS += CS_PE;
    }

    if ( parameters->physics_list[PHOTON_COMPTON] )
    {
        CS_CPT = get_CS_from_table( photon_CS_table->E_bins, photon_CS_table->Compton_Std_CS,
                                    energy, E_index, CS_index );
        sum_CS += CS_CPT;
    }

    if ( parameters->physics_list[PHOTON_RAYLEIGH] )
    {
        CS_RAY = get_CS_from_table( photon_CS_table->E_bins, photon_CS_table->Rayleigh_Lv_CS,
                                    energy, E_index, CS_index );
        sum_CS += CS_RAY;
    }

    f32 rnd = prng_uniform( particles, part_id );

    if ( rnd > sum_CS * CS_max  )
    {
        // Fictive interaction, keep going!
        return;
    }

    //// Apply discrete process //////////////////////////////////////////////////

    // Resolve process
    if ( parameters->physics_list[PHOTON_PHOTOELECTRIC] )
    {
        rnd = prng_uniform( particles, part_id );
        interaction_distance = -log( rnd ) / CS_PE;
        if ( interaction_distance < next_interaction_distance )
        {
            next_interaction_distance = interaction_distance;
            next_discrete_process = PHOTON_PHOTOELECTRIC;
        }
    }

    if ( parameters->physics_list[PHOTON_COMPTON] )
    {
        rnd = prng_uniform( particles, part_id );
        interaction_distance = -log( rnd ) / CS_CPT;
        if ( interaction_distance < next_interaction_distance )
        {
            next_interaction_distance = interaction_distance;
            next_discrete_process = PHOTON_COMPTON;
        }
    }

    if ( parameters->physics_list[PHOTON_RAYLEIGH] )
    {
        rnd = prng_uniform( particles, part_id );
        interaction_distance = -log( rnd ) / CS_RAY;
        if ( interaction_distance < next_interaction_distance )
        {
            next_interaction_distance = interaction_distance;
            next_discrete_process = PHOTON_RAYLEIGH;
        }
    }

    // Apply discrete process
    SecParticle electron;
    electron.endsimu = PARTICLE_DEAD;
    electron.dir.x = 0.;
    electron.dir.y = 0.;
    electron.dir.z = 1.;
    electron.E = 0.;

    if ( next_discrete_process == PHOTON_COMPTON )
    {
        electron = Compton_SampleSecondaries_standard( particles, materials->electron_energy_cut[mat_id],
                                                       parameters->secondaries_list[ELECTRON], part_id );
    }

    if ( next_discrete_process == PHOTON_PHOTOELECTRIC )
    {
        electron = Photoelec_SampleSecondaries_standard( particles, materials, photon_CS_table,
                                                         E_index, materials->electron_energy_cut[mat_id],
                                                         mat_id, parameters->secondaries_list[ELECTRON], part_id );
    }

    if ( next_discrete_process == PHOTON_RAYLEIGH )
    {
        Rayleigh_SampleSecondaries_Livermore( particles, materials, photon_CS_table, E_index, mat_id, part_id );
    }

    /// Energy cut /////////////

    // If gamma particle not enough energy (Energy cut)
    if ( particles->E[ part_id ] <= materials->photon_energy_cut[ mat_id ] )
    {
        // Kill without mercy
        particles->status[ part_id ] = PARTICLE_DEAD;
    }

    /// Drop energy ////////////

    // If gamma particle is dead (PE, Compton or energy cut)
    if ( particles->status[ part_id ] == PARTICLE_DEAD &&  particles->E[ part_id ] != 0.0f )
    {
        dose_record_standard( dosi, particles->E[ part_id ], pos.x,
                              pos.y, pos.z );
    }

    // If electron particle has energy
    if ( electron.E != 0.0f )
    {
        dose_record_standard( dosi, electron.E, pos.x,
                              pos.y, pos.z );
    }

}

/// Experimental Super Voxel Woodcock ///////////////////////////////////////////////

__host__ __device__ void VPVRTN::track_to_out_svw (ParticlesData *particles,
                                                   const VoxVolumeData<ui16> *vol,
                                                   const MaterialsData *materials,
                                                   const PhotonCrossSectionData *photon_CS_table,
                                                   const GlobalSimulationParametersData *parameters,
                                                   DoseData *dosi,
                                                   f32* mumax_table,
                                                   ui16* mumax_index_table,
                                                   ui32 part_id ,
                                                   ui32 nb_bins_sup_voxel )
{
    f32 sv_spacing_x = nb_bins_sup_voxel * vol->spacing_x;
    f32 sv_spacing_y = nb_bins_sup_voxel * vol->spacing_y;
    f32 sv_spacing_z = nb_bins_sup_voxel * vol->spacing_z;

    // Read position
    f32xyz pos;
    pos.x = particles->px[part_id];
    pos.y = particles->py[part_id];
    pos.z = particles->pz[part_id];

    // Read direction
    f32xyz dir;
    dir.x = particles->dx[part_id];
    dir.y = particles->dy[part_id];
    dir.z = particles->dz[part_id];

    // Vars
    f32 next_interaction_distance;
    f32 interaction_distance;

    //// Find next discrete interaction ///////////////////////////////////////

    // Defined index phantom
    f32xyz ivoxsize;
    ivoxsize.x = 1.0 / vol->spacing_x;
    ivoxsize.y = 1.0 / vol->spacing_y;
    ivoxsize.z = 1.0 / vol->spacing_z;
    ui32xyzw index_phantom;
    index_phantom.x = ui32( ( pos.x + vol->off_x ) * ivoxsize.x );
    index_phantom.y = ui32( ( pos.y + vol->off_y ) * ivoxsize.y );
    index_phantom.z = ui32( ( pos.z + vol->off_z ) * ivoxsize.z );

    index_phantom.w = index_phantom.z*vol->nb_vox_x*vol->nb_vox_y
            + index_phantom.y*vol->nb_vox_x
            + index_phantom.x; // linear index

    // Search the energy index to read CS
    f32 energy = particles->E[part_id];
    ui32 E_index = binary_search( energy, photon_CS_table->E_bins,
                                  photon_CS_table->nb_bins );

    // Get index CS table the coresponding super voxel
    ui32 CS_max_index = mumax_index_table[ index_phantom.w * photon_CS_table->nb_bins + E_index ] * photon_CS_table->nb_bins + E_index;

    f32 CS_max = ( E_index == 0 )? mumax_table[CS_max_index]: linear_interpolation(photon_CS_table->E_bins[E_index-1], mumax_table[CS_max_index-1],
            photon_CS_table->E_bins[E_index], mumax_table[CS_max_index], energy);

    // Woodcock tracking
    next_interaction_distance = -log( prng_uniform( particles, part_id ) ) * CS_max;
    interaction_distance  = next_interaction_distance;

    //// Get the next distance boundary volume /////////////////////////////////

    ui32 sv_index_phantom_x = index_phantom.x / nb_bins_sup_voxel;
    ui32 sv_index_phantom_y = index_phantom.y / nb_bins_sup_voxel;
    ui32 sv_index_phantom_z = index_phantom.z / nb_bins_sup_voxel;

    f32 sv_vox_xmin = sv_index_phantom_x*sv_spacing_x - vol->off_x;
    f32 sv_vox_ymin = sv_index_phantom_y*sv_spacing_y - vol->off_y;
    f32 sv_vox_zmin = sv_index_phantom_z*sv_spacing_z - vol->off_z;
    f32 sv_vox_xmax = sv_vox_xmin + sv_spacing_x;
    f32 sv_vox_ymax = sv_vox_ymin + sv_spacing_y;
    f32 sv_vox_zmax = sv_vox_zmin + sv_spacing_z;

    // get a safety position for the particle within this super voxel (sometime a particle can be right between two super voxels)

    pos = transport_get_safety_inside_AABB( pos, sv_vox_xmin, sv_vox_xmax,
                                            sv_vox_ymin, sv_vox_ymax, sv_vox_zmin, sv_vox_zmax, parameters->geom_tolerance );

    f32 boundary_distance = hit_ray_AABB( pos, dir, sv_vox_xmin, sv_vox_xmax,
                                          sv_vox_ymin, sv_vox_ymax, sv_vox_zmin, sv_vox_zmax );

    //// Move particle //////////////////////////////////////////////////////

    ui8 next_discrete_process = 0;
    if ( boundary_distance <= next_interaction_distance )
    {
        next_interaction_distance = boundary_distance + parameters->geom_tolerance; // Overshoot
        next_discrete_process = GEOMETRY_BOUNDARY;

        // get the new position
        pos = fxyz_add( pos, fxyz_scale( dir, next_interaction_distance ) );

        // get safety position (outside the current voxel)
        pos = transport_get_safety_outside_AABB( pos, sv_vox_xmin, sv_vox_xmax,
                                                 sv_vox_ymin, sv_vox_ymax, sv_vox_zmin, sv_vox_zmax, parameters->geom_tolerance );
    }
    else
    {
        // get the new position
        pos = fxyz_add( pos, fxyz_scale( dir, next_interaction_distance ) );
    }

    // Stop simulation if out of the phantom
    if ( !test_point_AABB_with_tolerance ( pos, vol->xmin, vol->xmax, vol->ymin, vol->ymax,
                                           vol->zmin, vol->zmax, parameters->geom_tolerance ) )
    {
        particles->status[part_id] = PARTICLE_FREEZE;
        return;
    }

    // store the new position
    particles->px[part_id] = pos.x;
    particles->py[part_id] = pos.y;
    particles->pz[part_id] = pos.z;

    if ( next_discrete_process != GEOMETRY_BOUNDARY )
    {

        //// Choose real or fictitious process ///////////////////////////////////////

        // Get the material that compose this volume
        index_phantom.x = ui32( ( pos.x + vol->off_x ) * ivoxsize.x );
        index_phantom.y = ui32( ( pos.y + vol->off_y ) * ivoxsize.y );
        index_phantom.z = ui32( ( pos.z + vol->off_z ) * ivoxsize.z );

        index_phantom.w = index_phantom.z*vol->nb_vox_x*vol->nb_vox_y
                + index_phantom.y*vol->nb_vox_x
                + index_phantom.x; // linear index

        ui16 mat_id = vol->values[ index_phantom.w ];

        // Get index CS table (considering mat id)
        ui32 CS_index = mat_id*photon_CS_table->nb_bins + E_index;
        f32 sum_CS = 0.0;
        f32 CS_PE = 0.0;
        f32 CS_CPT = 0.0;
        f32 CS_RAY = 0.0;
        next_interaction_distance = F32_MAX;

        if ( parameters->physics_list[PHOTON_PHOTOELECTRIC] )
        {
            CS_PE = get_CS_from_table( photon_CS_table->E_bins, photon_CS_table->Photoelectric_Std_CS,
                                       energy, E_index, CS_index );
            sum_CS += CS_PE;
        }

        if ( parameters->physics_list[PHOTON_COMPTON] )
        {
            CS_CPT = get_CS_from_table( photon_CS_table->E_bins, photon_CS_table->Compton_Std_CS,
                                        energy, E_index, CS_index );
            sum_CS += CS_CPT;
        }

        if ( parameters->physics_list[PHOTON_RAYLEIGH] )
        {
            CS_RAY = get_CS_from_table( photon_CS_table->E_bins, photon_CS_table->Rayleigh_Lv_CS,
                                        energy, E_index, CS_index );
            sum_CS += CS_RAY;
        }

        f32 rnd = prng_uniform( particles, part_id );

        if ( rnd > sum_CS * CS_max )
        {
            // Fictive interaction
            return;
        }

        //// Apply discrete process //////////////////////////////////////////////////

        // Resolve process
        if ( parameters->physics_list[PHOTON_PHOTOELECTRIC] )
        {
            rnd = prng_uniform( particles, part_id );
            interaction_distance = -log( rnd ) / CS_PE;
            if ( interaction_distance < next_interaction_distance )
            {
                next_interaction_distance = interaction_distance;
                next_discrete_process = PHOTON_PHOTOELECTRIC;
            }
        }

        if ( parameters->physics_list[PHOTON_COMPTON] )
        {
            rnd = prng_uniform( particles, part_id );
            interaction_distance = -log( rnd ) / CS_CPT;
            if ( interaction_distance < next_interaction_distance )
            {
                next_interaction_distance = interaction_distance;
                next_discrete_process = PHOTON_COMPTON;
            }
        }

        if ( parameters->physics_list[PHOTON_RAYLEIGH] )
        {
            rnd = prng_uniform( particles, part_id );
            interaction_distance = -log( rnd ) / CS_RAY;
            if ( interaction_distance < next_interaction_distance )
            {
                next_interaction_distance = interaction_distance;
                next_discrete_process = PHOTON_RAYLEIGH;
            }
        }


        // Apply discrete process
        SecParticle electron;
        electron.endsimu = PARTICLE_DEAD;
        electron.dir.x = 0.;
        electron.dir.y = 0.;
        electron.dir.z = 1.;
        electron.E = 0.;

        if ( next_discrete_process == PHOTON_COMPTON )
        {
            electron = Compton_SampleSecondaries_standard( particles, materials->electron_energy_cut[mat_id],
                                                           parameters->secondaries_list[ELECTRON], part_id );
        }

        if ( next_discrete_process == PHOTON_PHOTOELECTRIC )
        {
            electron = Photoelec_SampleSecondaries_standard( particles, materials, photon_CS_table,
                                                             E_index, materials->electron_energy_cut[mat_id],
                                                             mat_id, parameters->secondaries_list[ELECTRON], part_id );
        }

        if ( next_discrete_process == PHOTON_RAYLEIGH )
        {
            Rayleigh_SampleSecondaries_Livermore( particles, materials, photon_CS_table, E_index, mat_id, part_id );
        }

        /// Energy cut /////////////

        // If gamma particle not enough energy (Energy cut)
        if ( particles->E[ part_id ] <= materials->photon_energy_cut[ mat_id ] )
        {
            // Kill without mercy
            particles->status[ part_id ] = PARTICLE_DEAD;
        }

        /// Drop energy ////////////

        // If gamma particle is dead (PE, Compton or energy cut)
        if ( particles->status[ part_id ] == PARTICLE_DEAD &&  particles->E[ part_id ] != 0.0f )
        {
            dose_record_standard( dosi, particles->E[ part_id ], pos.x, pos.y, pos.z );
        }

        // If electron particle has energy
        if ( electron.E != 0.0f )
        {
            dose_record_standard( dosi, electron.E, pos.x, pos.y, pos.z );
        }
    }
}

/// Experimental SVW + TLE with Siddon algorithm  ///////////////////////////////////////////////

__host__ __device__ void VPVRTN::track_to_out_svw_tle (ParticlesData *particles,
                                                   const VoxVolumeData<ui16> *vol,
                                                   const MaterialsData *materials,
                                                   const PhotonCrossSectionData *photon_CS_table,
                                                   const GlobalSimulationParametersData *parameters,
                                                   DoseData *dosi,
                                                   f32* mumax_table,
                                                   ui16* mumax_index_table,
                                                   ui32 part_id ,
                                                   ui32 nb_bins_sup_voxel,
                                                   const VRT_Mu_MuEn_Data *mu_table )
{
    f32 sv_spacing_x = nb_bins_sup_voxel * vol->spacing_x;
    f32 sv_spacing_y = nb_bins_sup_voxel * vol->spacing_y;
    f32 sv_spacing_z = nb_bins_sup_voxel * vol->spacing_z;

    // Read position
    f32xyz pos;
    pos.x = particles->px[part_id];
    pos.y = particles->py[part_id];
    pos.z = particles->pz[part_id];

    // Read direction
    f32xyz dir;
    dir.x = particles->dx[part_id];
    dir.y = particles->dy[part_id];
    dir.z = particles->dz[part_id];

    // Vars
    f32 next_interaction_distance;

    //// Find next discrete interaction ///////////////////////////////////////

    // Defined index phantom
    f32xyz ivoxsize;
    ivoxsize.x = 1.0 / vol->spacing_x;
    ivoxsize.y = 1.0 / vol->spacing_y;
    ivoxsize.z = 1.0 / vol->spacing_z;
    ui32xyzw current_index_phantom;
    current_index_phantom.x = ui32( ( pos.x + vol->off_x ) * ivoxsize.x );
    current_index_phantom.y = ui32( ( pos.y + vol->off_y ) * ivoxsize.y );
    current_index_phantom.z = ui32( ( pos.z + vol->off_z ) * ivoxsize.z );

    current_index_phantom.w = current_index_phantom.z*vol->nb_vox_x*vol->nb_vox_y
            + current_index_phantom.y*vol->nb_vox_x
            + current_index_phantom.x; // linear index

    // Search the energy index to read CS
    f32 energy = particles->E[part_id];
    ui32 E_index = binary_search( energy, photon_CS_table->E_bins,
                                  photon_CS_table->nb_bins );

    // Get index CS table the coresponding super voxel
    ui32 CS_max_index = mumax_index_table[ current_index_phantom.w * photon_CS_table->nb_bins + E_index ] * photon_CS_table->nb_bins + E_index;

    f32 CS_max = ( E_index == 0 )? mumax_table[CS_max_index]: linear_interpolation(photon_CS_table->E_bins[E_index-1], mumax_table[CS_max_index-1],
            photon_CS_table->E_bins[E_index], mumax_table[CS_max_index], energy);

    // Woodcock tracking
    next_interaction_distance = -log( prng_uniform( particles, part_id ) ) * CS_max;

    //// Get the next distance boundary volume /////////////////////////////////

    ui32 sv_index_phantom_x = current_index_phantom.x / nb_bins_sup_voxel;
    ui32 sv_index_phantom_y = current_index_phantom.y / nb_bins_sup_voxel;
    ui32 sv_index_phantom_z = current_index_phantom.z / nb_bins_sup_voxel;

    f32 sv_vox_xmin = sv_index_phantom_x*sv_spacing_x - vol->off_x;
    f32 sv_vox_ymin = sv_index_phantom_y*sv_spacing_y - vol->off_y;
    f32 sv_vox_zmin = sv_index_phantom_z*sv_spacing_z - vol->off_z;
    f32 sv_vox_xmax = sv_vox_xmin + sv_spacing_x;
    f32 sv_vox_ymax = sv_vox_ymin + sv_spacing_y;
    f32 sv_vox_zmax = sv_vox_zmin + sv_spacing_z;

    // get a safety position for the particle within this super voxel (sometime a particle can be right between two super voxels)

    pos = transport_get_safety_inside_AABB( pos, sv_vox_xmin, sv_vox_xmax,
                                            sv_vox_ymin, sv_vox_ymax, sv_vox_zmin, sv_vox_zmax, parameters->geom_tolerance );

    f32 boundary_distance = hit_ray_AABB( pos, dir, sv_vox_xmin, sv_vox_xmax,
                                          sv_vox_ymin, sv_vox_ymax, sv_vox_zmin, sv_vox_zmax );

    //// Move particle //////////////////////////////////////////////////////

    ui8 next_discrete_process = 0;
    if ( boundary_distance <= next_interaction_distance )
    {
        next_interaction_distance = boundary_distance + parameters->geom_tolerance; // Overshoot
        next_discrete_process = GEOMETRY_BOUNDARY;

        // get the new position
        pos = fxyz_add( pos, fxyz_scale( dir, next_interaction_distance ) );

        // get safety position (outside the current voxel)
        pos = transport_get_safety_outside_AABB( pos, sv_vox_xmin, sv_vox_xmax,
                                                 sv_vox_ymin, sv_vox_ymax, sv_vox_zmin, sv_vox_zmax, parameters->geom_tolerance );
    }
    else
    {
        // get the new position
        pos = fxyz_add( pos, fxyz_scale( dir, next_interaction_distance ) );
    }

    // Stop simulation if out of the phantom
    if ( !test_point_AABB_with_tolerance ( pos, vol->xmin, vol->xmax, vol->ymin, vol->ymax,
                                           vol->zmin, vol->zmax, parameters->geom_tolerance ) )
    {
        particles->status[part_id] = PARTICLE_FREEZE;
        return;
    }

    // Get the material that compose this volume
    ui32xyzw next_index_phantom;
    next_index_phantom.x = ui32( ( pos.x + vol->off_x ) * ivoxsize.x );
    next_index_phantom.y = ui32( ( pos.y + vol->off_y ) * ivoxsize.y );
    next_index_phantom.z = ui32( ( pos.z + vol->off_z ) * ivoxsize.z );

    next_index_phantom.w = next_index_phantom.z*vol->nb_vox_x*vol->nb_vox_y
            + next_index_phantom.y*vol->nb_vox_x
            + next_index_phantom.x; // linear index

    ui16 mat_id = vol->values[ next_index_phantom.w ];

    // Get index CS table (considering mat id)
    ui32 CS_index = mat_id*photon_CS_table->nb_bins + E_index;



    //// Choose real or fictitious process ///////////////////////////////////////

    f32 sum_CS = 0.0;
    f32 CS_PE = 0.0;
    f32 CS_CPT = 0.0;
    f32 CS_RAY = 0.0;

    if ( parameters->physics_list[PHOTON_PHOTOELECTRIC] )
    {
        CS_PE = get_CS_from_table( photon_CS_table->E_bins, photon_CS_table->Photoelectric_Std_CS,
                                   energy, E_index, CS_index );
        sum_CS += CS_PE;
    }

    if ( parameters->physics_list[PHOTON_COMPTON] )
    {
        CS_CPT = get_CS_from_table( photon_CS_table->E_bins, photon_CS_table->Compton_Std_CS,
                                    energy, E_index, CS_index );
        sum_CS += CS_CPT;
    }

    if ( parameters->physics_list[PHOTON_RAYLEIGH] )
    {
        CS_RAY = get_CS_from_table( photon_CS_table->E_bins, photon_CS_table->Rayleigh_Lv_CS,
                                    energy, E_index, CS_index );
        sum_CS += CS_RAY;
    }

    f32 rnd = prng_uniform( particles, part_id );

    if ( rnd > sum_CS * CS_max )
    {
        // Fictive interaction
        return;
    }

    //// Apply TLE process //////////////////////////////////////////////////
    if ( next_discrete_process != GEOMETRY_BOUNDARY )
    {
        // Resolve discrete process
        SecParticle electron = photon_resolve_discrete_process ( particles, parameters, photon_CS_table,
                                                                 materials, mat_id, part_id ); // discrete process
    }

    /// Drop energy ////////////

    // Get the mu_en for the current E
    E_index = binary_search ( energy, mu_table->E_bins, mu_table->nb_bins );


    // Siddon algorithm for calculating the intersection points

    i32 stepX = 1, stepY = 1, stepZ = 1;
    ui32 x = current_index_phantom.x, y = current_index_phantom.y, z = current_index_phantom.z;
    f32 tDeltaX = vol->spacing_x / fabs(dir.x);
    f32 tDeltaY = vol->spacing_y / fabs(dir.y);
    f32 tDeltaZ = vol->spacing_z / fabs(dir.z);
    f32 tMaxX, tMaxY, tMaxZ;
    if ( dir.x < 0 )
    {
        stepX = -1;
        tMaxX = ( ( current_index_phantom.x ) * vol->spacing_x - particles->px[part_id] - vol->off_x ) / dir.x;
    }
    if ( dir.x > 0 )
    {
        tMaxX = ( ( current_index_phantom.x + 1 ) * vol->spacing_x - particles->px[part_id] - vol->off_x) / dir.x;
    }
    if ( dir.y < 0 )
    {
        stepY = -1;
        tMaxY = ( ( current_index_phantom.y ) * vol->spacing_y - particles->py[part_id] - vol->off_y) / dir.y;
    }
    if ( dir.y > 0 )
    {
        tMaxY = ( ( current_index_phantom.y + 1 ) * vol->spacing_y - particles->py[part_id] - vol->off_y) / dir.y;
    }
    if ( dir.z < 0 )
    {
        stepZ = -1;
        tMaxZ = ( ( current_index_phantom.z ) * vol->spacing_z - particles->pz[part_id] - vol->off_z) / dir.z;
    }
    if ( dir.z > 0 )
    {
        tMaxZ = ( ( current_index_phantom.z + 1 ) * vol->spacing_z - particles->pz[part_id] - vol->off_z) / dir.z;
    }


    bool out = false;
    ui32 X = current_index_phantom.x;
    ui32 Y = current_index_phantom.y;
    ui32 Z = current_index_phantom.z;
    f32 interaction_distance;
    f32 previous_dist = 0.0;
    f32 mu_en;
    ui32 index_phantom;
    f32 tMax;

    while( !out )
    {
        tMax = tMaxX;
        if ( tMaxY < tMax ) { tMax = tMaxY; }
        if ( tMaxZ < tMax ) { tMax = tMaxZ; }
        out = tMax > next_interaction_distance;
        if( out ) { interaction_distance = next_interaction_distance - previous_dist; break; }
        interaction_distance = tMax - previous_dist;
        previous_dist = tMax;

        if ( tMaxX == tMax ) { x += stepX; tMaxX += tDeltaX; }
        if ( tMaxY == tMax ) { y += stepY; tMaxY += tDeltaY; }
        if ( tMaxZ == tMax ) { z += stepZ; tMaxZ += tDeltaZ; }


        //TLE dose record for the crossed voxels

        index_phantom = Z *vol->nb_vox_x*vol->nb_vox_y + Y * vol->nb_vox_x + X; // linear index

        mat_id = vol->values[ index_phantom ];
        if ( E_index == 0 )
        {
            mu_en = mu_table->mu_en[ mat_id*mu_table->nb_bins ];
        }
        else
        {
            mu_en = linear_interpolation( mu_table->E_bins[E_index-1],  mu_table->mu_en[mat_id*mu_table->nb_bins + E_index-1],
                    mu_table->E_bins[E_index],    mu_table->mu_en[mat_id*mu_table->nb_bins + E_index],
                    energy );
        }

        dose_record_TLE( dosi, energy, X * vol->spacing_x - vol->off_x, Y * vol->spacing_y - vol->off_y, Z * vol->spacing_z - vol->off_z, interaction_distance /* / materials->density[ mat_id ] */, mu_en );

        /// Energy cut /////////////

        // If gamma particle not enough energy (Energy cut)
        if ( particles->E[ part_id ] <= materials->photon_energy_cut[ mat_id ] )
        {
            // Kill without mercy
            particles->status[ part_id ] = PARTICLE_DEAD;
        }
        X = x;
        Y = y;
        Z = z;
    }

    //TLE dose record for the last voxel

    index_phantom = Z *vol->nb_vox_x*vol->nb_vox_y + Y * vol->nb_vox_x + X; // linear index

    mat_id = vol->values[ index_phantom ];
    if ( E_index == 0 )
    {
        mu_en = mu_table->mu_en[ mat_id*mu_table->nb_bins ];
    }
    else
    {
        mu_en = linear_interpolation( mu_table->E_bins[E_index-1],  mu_table->mu_en[mat_id*mu_table->nb_bins + E_index-1],
                mu_table->E_bins[E_index],    mu_table->mu_en[mat_id*mu_table->nb_bins + E_index],
                energy );
    }

    dose_record_TLE( dosi, energy, X * vol->spacing_x - vol->off_x, Y * vol->spacing_y - vol->off_y, Z * vol->spacing_z - vol->off_z, interaction_distance /* / materials->density[ mat_id ] */, mu_en );

    /// Energy cut /////////////

    // If gamma particle not enough energy (Energy cut)
    if ( particles->E[ part_id ] <= materials->photon_energy_cut[ mat_id ] )
    {
        // Kill without mercy
        particles->status[ part_id ] = PARTICLE_DEAD;
    }


    // store the new position
    particles->px[part_id] = pos.x;
    particles->py[part_id] = pos.y;
    particles->pz[part_id] = pos.z;

}


/*
// Se TLE function
__host__ __device__ void VPVRTN::track_seTLE( ParticlesData particles,
                                               VoxVolumeData<ui16> vol,
                                               COOHistoryMap coo_hist_map,
                                               DoseData dose,
                                               Mu_MuEn_Table mu_table,
                                               ui32 nb_of_rays, f32 edep_th, ui32 id )
{
    // Read an interaction position
    ui16 vox_x = coo_hist_map.x[ id ];
    ui16 vox_y = coo_hist_map.y[ id ];
    ui16 vox_z = coo_hist_map.z[ id ];

    // Nb of interaction and total energy
    ui32 nb_int = coo_hist_map.interaction[ id ];
    f32 mean_energy = coo_hist_map.energy[ id ] / f32( nb_int );

    // Total nb of rays is given by the ponderation of the nb of interactions
    nb_of_rays *= nb_int;

    // Weight in
    f32 win_init = 1 / f32( nb_of_rays );

    // vars DDA
    ui32 n;
    f32 length;

    f32 flength;
    f32 lx, ly, lz;
    f32 fxinc, fyinc, fzinc, fx, fy, fz;
    ui32 ix, iy, iz;
    f32 diffx, diffy, diffz;

    ui32 step = vol.nb_vox_x * vol.nb_vox_y;
    ui32 ind;

    // Rnd ray
    f32 phi, theta;
    f32xyz ray_p, ray_q, ray_d;
    f32 aabb_dist;

    // seTLE
    ui16 mat_id;
    ui32 E_index;
    f32 mu, mu_en, path_length;
    f32 win, wout, edep;

    // Pre-compute the energy index to access to the mu and mu_en tables
    E_index = binary_search ( mean_energy, mu_table.E_bins, mu_table.nb_bins );

    // Loop over raycasting
    ui32 iray=0; while ( iray < nb_of_rays )
    {
        // Generate a ray
        ray_p.x = f32(vox_x) + 0.5f;  // Center of the voxel
        ray_p.y = f32(vox_y) + 0.5f;  // Center of the voxel
        ray_p.z = f32(vox_z) + 0.5f;  // Center of the voxel

        phi = prng_uniform( particles, id );
        theta = prng_uniform( particles, id );
        phi  *= gpu_twopi;
        theta = acosf ( 1.0f - 2.0f*theta );
        ray_d.x = cosf( phi ) * sinf( theta );
        ray_d.y = sinf( phi ) * sinf( theta );
        ray_d.z = cosf( theta );

        // Get the second voxel point for the ray
        aabb_dist = hit_ray_AABB(ray_p, ray_d, 0, vol.nb_vox_x, 0, vol.nb_vox_y, 0, vol.nb_vox_z);
        ray_q = fxyz_add ( ray_p, fxyz_scale ( ray_d, aabb_dist ) );

        // DDA params
        diffx = floorf( ray_q.x ) - vox_x;
        diffy = floorf( ray_q.y ) - vox_y;
        diffz = floorf( ray_q.z ) - vox_z;

        lx = fabsf( diffx );
        ly = fabsf( diffy );
        lz = fabsf( diffz );

        length = fmaxf( ly, fmaxf( lx, lz ) );
        flength = 1.0 / length;

        fxinc = diffx * flength;
        fyinc = diffy * flength;
        fzinc = diffz * flength;

        fx = ray_p.x;
        fy = ray_p.y;
        fz = ray_p.z;

        // Path length of the increment step in mm
        path_length = powf( (fxinc*vol.spacing_x)*(fxinc*vol.spacing_x) +
                            (fyinc*vol.spacing_y)*(fyinc*vol.spacing_y) +
                            (fzinc*vol.spacing_z)*(fzinc*vol.spacing_z), 0.5f );

        // Init the particle weigth
        win = win_init;

        // DDA loop
        n = 0; while ( n < length )
        {
            ix = (ui32)fx; iy = (ui32)fy; iz = (ui32)fz;

            // if inside the volume
            if (fx >= 0 && fy >= 0 && fz >= 0 &&
                ix < vol.nb_vox_x && iy < vol.nb_vox_y && iz < vol.nb_vox_z
                && n != 0 )
            {

                // get index and accumulate
                ind = iz*step + iy*vol.nb_vox_x + ix;

                // Read material
                mat_id = vol.values[ ind ];

                // Get mu and mu_en for the current E
                if ( E_index == 0 )
                {
                    mu = mu_table.mu[ mat_id*mu_table.nb_bins ];
                    mu_en = mu_table.mu_en[ mat_id*mu_table.nb_bins ];
                }
                else
                {
                    mu = linear_interpolation( mu_table.E_bins[E_index-1],  mu_table.mu[mat_id*mu_table.nb_bins + E_index-1],
                                               mu_table.E_bins[E_index],    mu_table.mu[mat_id*mu_table.nb_bins + E_index],
                                               mean_energy );

                    mu_en = linear_interpolation( mu_table.E_bins[E_index-1],  mu_table.mu_en[mat_id*mu_table.nb_bins + E_index-1],
                                                  mu_table.E_bins[E_index],    mu_table.mu_en[mat_id*mu_table.nb_bins + E_index],
                                                  mean_energy );
                }

                // Compute the weight out
                wout = win * expf( -mu * path_length / 10.0 ); // Factor from GATE?? - JB

                // Compute the energy to drop
                edep = mean_energy * mu_en/mu * ( win - wout );

                // Drop energy
                ggems_atomic_add_f64( dose.edep, ind, f64( edep ) );
                ggems_atomic_add_f64( dose.edep_squared, ind, f64( edep) * f64( edep ) );
                ggems_atomic_add( dose.number_of_hits, ind, ui32 ( 1 ) );

                // Update the weight
                win = wout;

                // Energy cut
                if (edep <= edep_th) break;

            }

            // step the line
            fx += fxinc;
            fy += fyinc;
            fz += fzinc;
            ++n;
        }

        ++iray;
    } // Rays

}
*/

/// KERNELS /////////////////////////////////


// Device Kernel that move particles to the voxelized volume boundary
__global__ void VPVRTN::kernel_device_track_to_in( ParticlesData *particles, f32 xmin, f32 xmax,
                                                   f32 ymin, f32 ymax, f32 zmin, f32 zmax, f32 tolerance )
{  
    const ui32 id = blockIdx.x * blockDim.x + threadIdx.x;
    if ( id >= particles->size ) return;
    transport_track_to_in_AABB( particles, xmin, xmax, ymin, ymax, zmin, zmax, tolerance, id);
}

// Device kernel that track particles within the voxelized volume until boundary
__global__ void VPVRTN::kernel_device_track_to_out_analog(ParticlesData *particles,
                                                           const VoxVolumeData<ui16> *vol,
                                                           const MaterialsData *materials,
                                                           const PhotonCrossSectionData *photon_CS_table,
                                                           const GlobalSimulationParametersData *parameters,
                                                           DoseData *dosi )
{
    const ui32 id = blockIdx.x * blockDim.x + threadIdx.x;
    if ( id >= particles->size ) return;

    // Stepping loop - Get out of loop only if the particle was dead and it was a primary
    while ( particles->status[id] != PARTICLE_DEAD && particles->status[id] != PARTICLE_FREEZE )
    {
        VPVRTN::track_to_out_analog( particles, vol, materials, photon_CS_table, parameters, dosi, id );
    }
}

// Device kernel that track particles within the voxelized volume until boundary
__global__ void VPVRTN::kernel_device_track_to_out_tle( ParticlesData *particles,
                                                        const VoxVolumeData<ui16> *vol,
                                                        const MaterialsData *materials,
                                                        const PhotonCrossSectionData *photon_CS_table,
                                                        const GlobalSimulationParametersData *parameters,
                                                        DoseData *dosi,
                                                        const VRT_Mu_MuEn_Data *mu_table )
{
    const ui32 id = blockIdx.x * blockDim.x + threadIdx.x;
    if ( id >= particles->size ) return;

    // Stepping loop - Get out of loop only if the particle was dead and it was a primary
    while ( particles->status[id] != PARTICLE_DEAD && particles->status[id] != PARTICLE_FREEZE )
    {
        VPVRTN::track_to_out_tle( particles, vol, materials, photon_CS_table,
                                  parameters, dosi, mu_table, id );
    }
}

/// Experimental

// Device kernel that track particles within the voxelized volume until boundary
__global__ void VPVRTN::kernel_device_track_to_out_woodcock( ParticlesData *particles,
                                                             const VoxVolumeData<ui16> *vol,
                                                             const MaterialsData *materials,
                                                             const PhotonCrossSectionData *photon_CS_table,
                                                             const GlobalSimulationParametersData *parameters,
                                                             DoseData *dosi,
                                                             f32* mumax_table )
{
    const ui32 id = blockIdx.x * blockDim.x + threadIdx.x;
    if ( id >= particles->size ) return;

    // Stepping loop - Get out of loop only if the particle was dead and it was a primary
    while ( particles->status[id] != PARTICLE_DEAD && particles->status[id] != PARTICLE_FREEZE )
    {
        VPVRTN::track_to_out_woodcock( particles, vol, materials, photon_CS_table,
                                       parameters, dosi, mumax_table, id );
    }
}

// Device kernel that track particles within the voxelized volume until super Voxel boundary
__global__ void VPVRTN::kernel_device_track_to_out_svw(ParticlesData *particles,
                                                        const VoxVolumeData<ui16> *vol,
                                                        const MaterialsData *materials,
                                                        const PhotonCrossSectionData *photon_CS_table,
                                                        const GlobalSimulationParametersData *parameters,
                                                        DoseData *dosi,
                                                        f32* mumax_table,
                                                        ui16* mumax_index_table,
                                                        ui32 nb_bins_sup_voxel )
{
    const ui32 id = blockIdx.x * blockDim.x + threadIdx.x;
    if ( id >= particles->size ) return;

    // Stepping loop - Get out of loop only if the particle was dead and it was a primary
    while ( particles->status[id] != PARTICLE_DEAD && particles->status[id] != PARTICLE_FREEZE )
    {
        VPVRTN::track_to_out_svw( particles, vol, materials, photon_CS_table,
                                  parameters, dosi, mumax_table, mumax_index_table, id, nb_bins_sup_voxel );
    }

}

// Device kernel that track particles within the voxelized volume until boundary until
// super Voxel boundary (Super Voxel Woodcock) with TLE dose deposition
__global__ void VPVRTN::kernel_device_track_to_out_svw_tle(ParticlesData *particles,
                                                        const VoxVolumeData<ui16> *vol,
                                                        const MaterialsData *materials,
                                                        const PhotonCrossSectionData *photon_CS_table,
                                                        const GlobalSimulationParametersData *parameters,
                                                        DoseData *dosi,
                                                        f32* mumax_table,
                                                        ui16* mumax_index_table,
                                                        ui32 nb_bins_sup_voxel,
                                                        const VRT_Mu_MuEn_Data *mu_table )
{
    const ui32 id = blockIdx.x * blockDim.x + threadIdx.x;
    if ( id >= particles->size ) return;

    // Stepping loop - Get out of loop only if the particle was dead and it was a primary
    while ( particles->status[id] != PARTICLE_DEAD && particles->status[id] != PARTICLE_FREEZE )
    {
        VPVRTN::track_to_out_svw_tle( particles, vol, materials, photon_CS_table,
                                  parameters, dosi, mumax_table, mumax_index_table, id, nb_bins_sup_voxel, mu_table );
    }

}

/*
// Device kernel that perform seTLE
__global__ void VPVRTN::kernel_device_seTLE( ParticlesData particles,
                                              VoxVolumeData<ui16> vol,
                                              COOHistoryMap coo_hist_map,
                                              DoseData dosi,
                                              Mu_MuEn_Table mu_table , ui32 nb_of_rays , f32 edep_th )
{
    const ui32 id = blockIdx.x * blockDim.x + threadIdx.x;
    if ( id >= coo_hist_map.nb_data ) return;

    VPVRTN::track_seTLE( particles, vol, coo_hist_map, dosi, mu_table, nb_of_rays, edep_th, id );
}

// Host kernel that perform seTLE
void VPVRTN::kernel_host_seTLE( ParticlesData particles,
                                 VoxVolumeData<ui16> vol,
                                 COOHistoryMap coo_hist_map,
                                 DoseData dosi,
                                 Mu_MuEn_Table mu_table , ui32 nb_of_rays , f32 edep_th )
{
    ui32 id = 0;
    while ( id < coo_hist_map.nb_data )
    {
        VPVRTN::track_seTLE( particles, vol, coo_hist_map, dosi, mu_table, nb_of_rays, edep_th, id );
        ++id;
    }
}
*/

///////////////////// Privates

bool VoxPhanVRTNav::m_check_mandatory()
{

    if ( m_phantom.h_volume->nb_vox_x == 0 || m_phantom.h_volume->nb_vox_y == 0 || m_phantom.h_volume->nb_vox_z == 0 ||
         m_phantom.h_volume->spacing_x == 0 || m_phantom.h_volume->spacing_y == 0 || m_phantom.h_volume->spacing_z == 0 ||
         m_phantom.list_of_materials.size() == 0 || m_materials_filename.empty() )
    {
        return false;
    }
    else
    {
        return true;
    }

}

// Init mu and mu_en table
void VoxPhanVRTNav::m_init_mu_table()
{
    // Load mu data
    f32 *energies  = new f32[mu_nb_energies];
    f32 *mu        = new f32[mu_nb_energies];
    f32 *mu_en     = new f32[mu_nb_energies];
    ui32 *mu_index = new ui32[mu_nb_elements];

    ui32 index_table = 0;
    ui32 index_data = 0;

    for (ui32 i= 0; i < mu_nb_elements; i++)
    {
        ui32 nb_energies = mu_nb_energy_bin[ i ];
        mu_index[ i ] = index_table;

        for (ui32 j = 0; j < nb_energies; j++)
        {
            energies[ index_table ] = mu_data[ index_data++ ];
            mu[ index_table ]       = mu_data[ index_data++ ];
            mu_en[ index_table ]    = mu_data[ index_data++ ];
            index_table++;
        }
    }

    // Build mu and mu_en according material
    ui32 n = mh_params->cs_table_nbins;
    ui32 k = m_materials.h_materials->nb_materials;

    mh_mu_table->E_bins = (f32*)malloc( n*sizeof(f32) );
    mh_mu_table->mu = (f32*)malloc( n*k*sizeof(f32) );
    mh_mu_table->mu_en = (f32*)malloc( n*k*sizeof(f32) );

    mh_mu_table->nb_mat = k;
    mh_mu_table->E_max = mh_params->cs_table_max_E;
    mh_mu_table->E_min = mh_params->cs_table_min_E;
    mh_mu_table->nb_bins = n;

    // Fill energy table with log scale
    f32 slope = log(mh_mu_table->E_max / mh_mu_table->E_min);
    ui32 i = 0;
    while (i < mh_mu_table->nb_bins) {
        mh_mu_table->E_bins[ i ] = mh_mu_table->E_min * exp( slope * ( (f32)i / ( (f32)mh_mu_table->nb_bins-1 ) ) ) * MeV;
        ++i;
    }

    // For each material and energy bin compute mu and muen
    ui32 imat = 0;
    ui32 abs_index, E_index, mu_index_E;
    ui32 iZ, Z;
    f32 energy, mu_over_rho, mu_en_over_rho, frac;
    while (imat < mh_mu_table->nb_mat) {

        // for each energy bin
        i=0; while (i < mh_mu_table->nb_bins) {

            // absolute index to store data within the table
            abs_index = imat*mh_mu_table->nb_bins + i;

            // Energy value
            energy = mh_mu_table->E_bins[ i ];

            // For each element of the material
            mu_over_rho = 0.0f; mu_en_over_rho = 0.0f;
            iZ=0; while (iZ < m_materials.h_materials->nb_elements[ imat ]) {

                // Get Z and mass fraction
                Z = m_materials.h_materials->mixture[ m_materials.h_materials->index[ imat ] + iZ ];
                frac = m_materials.h_materials->mass_fraction[ m_materials.h_materials->index[ imat ] + iZ ];

                // Get energy index
                mu_index_E = mu_index_energy[ Z ];
                E_index = binary_search ( energy, energies, mu_index_E+mu_nb_energy_bin[ Z ], mu_index_E );

                // Get mu an mu_en from interpolation
                if ( E_index == mu_index_E )
                {
                    mu_over_rho += mu[ E_index ];
                    mu_en_over_rho += mu_en[ E_index ];
                }
                else
                {
                    mu_over_rho += frac * linear_interpolation(energies[E_index-1],  mu[E_index-1],
                            energies[E_index],    mu[E_index],
                            energy);
                    mu_en_over_rho += frac * linear_interpolation(energies[E_index-1],  mu_en[E_index-1],
                            energies[E_index],    mu_en[E_index],
                            energy);
                }
                ++iZ;
            }

            // Store values
            mh_mu_table->mu[ abs_index ] = mu_over_rho * m_materials.h_materials->density[ imat ] / (g/cm3);
            mh_mu_table->mu_en[ abs_index ] = mu_en_over_rho * m_materials.h_materials->density[ imat ] / (g/cm3);

            ++i;

        } // E bin

        ++imat;


    } // Mat


    ////  GPU copy handling  ////////////////////////:


    /// First, struct allocation
    HANDLE_ERROR( cudaMalloc( (void**) &md_mu_table, sizeof( VRT_Mu_MuEn_Data ) ) );

    /// Device pointers allocation
    f32* d_E_bins;      // n
    HANDLE_ERROR( cudaMalloc((void**) &d_E_bins, n*sizeof(f32)) );
    f32* d_mu;          // n*k
    HANDLE_ERROR( cudaMalloc((void**) &d_mu, n*k*sizeof(f32)) );
    f32* d_mu_en;       // n*k
    HANDLE_ERROR( cudaMalloc((void**) &d_mu_en, n*k*sizeof(f32)) );

    /// Copy host data to device
    HANDLE_ERROR( cudaMemcpy( d_E_bins, mh_mu_table->E_bins,
                              n*sizeof(f32), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( d_mu, mh_mu_table->mu,
                              n*k*sizeof(f32), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( d_mu_en, mh_mu_table->mu_en,
                              n*k*sizeof(f32), cudaMemcpyHostToDevice ) );

    /// Bind data to the struct
    HANDLE_ERROR( cudaMemcpy( &(md_mu_table->E_bins), &d_E_bins,
                              sizeof(md_mu_table->E_bins), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_mu_table->mu), &d_mu,
                              sizeof(md_mu_table->mu), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_mu_table->mu_en), &d_mu_en,
                              sizeof(md_mu_table->mu_en), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_mu_table->nb_mat), &k,
                              sizeof(md_mu_table->nb_mat), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_mu_table->nb_bins), &n,
                              sizeof(md_mu_table->nb_bins), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_mu_table->E_min), &(mh_mu_table->E_min),
                              sizeof(md_mu_table->E_min), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_mu_table->E_max), &(mh_mu_table->E_max),
                              sizeof(md_mu_table->E_max), cudaMemcpyHostToDevice ) );

}

/*
// Compress history map to be process by the GPU (in a non-sparse way)
void VoxPhanVRTNav::m_compress_history_map()
{
    // 1. count the number of non-zero
    ui32 ct = 0; ui32 i = 0; ui32 val_int;
    while ( i < m_phantom.h_volume->number_of_voxels )
    {
        val_int = m_hist_map.interaction[ i++ ];
        if ( val_int ) ++ct;
    }
    m_coo_hist_map.nb_data = ct;
    GGcout << "Coo History map has " << ct << " non-zeros" << GGendl;

    // 2. init memory
    HANDLE_ERROR( cudaMallocManaged( &(m_coo_hist_map.x), ct * sizeof( ui16 ) ) );
    HANDLE_ERROR( cudaMallocManaged( &(m_coo_hist_map.y), ct * sizeof( ui16 ) ) );
    HANDLE_ERROR( cudaMallocManaged( &(m_coo_hist_map.z), ct * sizeof( ui16 ) ) );
    HANDLE_ERROR( cudaMallocManaged( &(m_coo_hist_map.energy), ct * sizeof( f32 ) ) );
    HANDLE_ERROR( cudaMallocManaged( &(m_coo_hist_map.interaction), ct * sizeof( ui32 ) ) );

    // 3. compressed data
    ui16 x, y, z;
    z = i = ct = 0;

    while ( z < m_phantom.h_volume->nb_vox_z )
    {
        y = 0;
        while ( y < m_phantom.h_volume->nb_vox_y )
        {
            x = 0;
            while ( x < m_phantom.h_volume->nb_vox_x )
            {
                val_int = m_hist_map.interaction[ i ];
                if ( val_int )
                {
                    m_coo_hist_map.x[ ct ] = x;
                    m_coo_hist_map.y[ ct ] = y;
                    m_coo_hist_map.z[ ct ] = z;
                    m_coo_hist_map.interaction[ ct ] = val_int;
                    m_coo_hist_map.energy[ ct ] = m_hist_map.energy[ i ];
                    ++ct;
                }
                ++i;
                ++x;
            }
            ++y;
        }
        ++z;
    }

}
*/

// return memory usage
ui64 VoxPhanVRTNav::m_get_memory_usage()
{
    ui64 mem = 0;

    // First the voxelized phantom
    mem += ( m_phantom.h_volume->number_of_voxels * sizeof( ui16 ) );

    // Then material data
    mem += ( ( 3 * m_materials.h_materials->nb_elements_total + 23 * m_materials.h_materials->nb_materials ) * sizeof( f32 ) );

    // Then cross sections (gamma)
    ui64 n = m_cross_sections.h_photon_CS->nb_bins;
    ui64 k = m_cross_sections.h_photon_CS->nb_mat;
    mem += ( ( n + 3*n*k + 3*101*n ) * sizeof( f32 ) );
    // Cross section (electron)
    mem += ( n*k*7*sizeof( f32 ) );

    // Finally the dose map
    n = m_dose_calculator.h_dose->tot_nb_dosels;
    mem += ( 2*n*sizeof( f64 ) + n*sizeof( ui32 ) );
    mem += ( 20 * sizeof( f32 ) );

    // If TLE
    if ( m_flag_vrt == VRT_TLE || m_flag_vrt == VRT_SETLE || m_flag_vrt == VRT_SVW_TLE )
    {
        n = mh_mu_table->nb_bins;
        mem += ( n*k*2 * sizeof( f32 ) ); // mu and mu_en
        mem += ( n*sizeof( f32 ) );       // energies
    }

    // If seTLE
    if ( m_flag_vrt == VRT_SETLE )
    {
        mem += ( m_phantom.h_volume->number_of_voxels * ( sizeof( ui32 ) + sizeof( f32 ) ) );
    }

    // If Woodcock
    if ( m_flag_vrt == VRT_WOODCOCK )
    {
        mem += m_cross_sections.h_photon_CS->nb_bins * sizeof(ui32);
    }

    // If Super Voxel Woodcock
    if ( m_flag_vrt == VRT_SVW || m_flag_vrt == VRT_SVW_TLE )
    {
        mem += m_cross_sections.h_photon_CS->nb_bins * sizeof(ui32);
    }

    return mem;
}

////:: Experimental

// Use for woodcock navigation
void VoxPhanVRTNav::m_build_mumax_table()
{
    // Init mumax table vector
    ui32 nb_bins_E = m_cross_sections.h_photon_CS->nb_bins;
    HANDLE_ERROR( cudaMallocManaged( &(m_mumax_table), nb_bins_E * sizeof( ui32 ) ) );

    // Find the most attenuate material
    f32 max_dens = 0.0;
    ui32 ind_mat = 0;
    ui32 i = 0; while ( i < m_materials.h_materials->nb_materials )
    {
        if ( m_materials.h_materials->density[i] > max_dens )
        {
            max_dens = m_materials.h_materials->density[ i ];
            ind_mat = i;
        }
        ++i;
    }

    // Build table using max density  [ 1 / Sum( CS ) ]
    i=0; while ( i < nb_bins_E )
    {
        ui32 index = ind_mat * nb_bins_E + i;
        f32 sum_CS = 0.0;

        if ( mh_params->physics_list[PHOTON_PHOTOELECTRIC] )
        {
            sum_CS += m_cross_sections.h_photon_CS->Photoelectric_Std_CS[ index ];
        }

        if ( mh_params->physics_list[PHOTON_COMPTON] )
        {
            sum_CS += m_cross_sections.h_photon_CS->Compton_Std_CS[ index ];
        }

        if ( mh_params->physics_list[PHOTON_RAYLEIGH] )
        {
            sum_CS += m_cross_sections.h_photon_CS->Rayleigh_Lv_CS[ index ];
        }

        m_mumax_table[ i ] = 1.0 / sum_CS;
        ++i;
    }
}

void VoxPhanVRTNav::m_build_svw_mumax_table()
{
    ui32 nb_bins_E = m_cross_sections.h_photon_CS->nb_bins;
    // Init voxel -> super voxel index
    ui32 *sup_vox_index = new ui32[m_phantom.h_volume->number_of_voxels];

    // Init the super voxel size
    ui32 nbx_sup_vox = (m_phantom.h_volume->nb_vox_x % m_nb_bins_sup_voxel == 0)
            ? m_phantom.h_volume->nb_vox_x / m_nb_bins_sup_voxel
            : m_phantom.h_volume->nb_vox_x / m_nb_bins_sup_voxel + 1;
    ui32 nby_sup_vox = (m_phantom.h_volume->nb_vox_y % m_nb_bins_sup_voxel == 0)
            ? m_phantom.h_volume->nb_vox_y / m_nb_bins_sup_voxel
            : m_phantom.h_volume->nb_vox_y / m_nb_bins_sup_voxel + 1;
    ui32 nbz_sup_vox = (m_phantom.h_volume->nb_vox_z % m_nb_bins_sup_voxel == 0)
            ? m_phantom.h_volume->nb_vox_z / m_nb_bins_sup_voxel
            : m_phantom.h_volume->nb_vox_z / m_nb_bins_sup_voxel + 1;

    // Init material mumax table
    f32 *mu_mat = new f32[ m_materials.h_materials->nb_materials  * nb_bins_E ];
    ui32 ind_mat = 0; while ( ind_mat < m_materials.h_materials->nb_materials )
    {
        ui32 n=0; while ( n < nb_bins_E )
        {
            ui32 index = ind_mat * nb_bins_E + n;
            f32 cs = 0.0;
            if ( mh_params->physics_list[PHOTON_PHOTOELECTRIC] )
            {
                cs += m_cross_sections.h_photon_CS->Photoelectric_Std_CS[ index ];
            }

            if ( mh_params->physics_list[PHOTON_COMPTON] )
            {
                cs += m_cross_sections.h_photon_CS->Compton_Std_CS[ index ];
            }

            if ( mh_params->physics_list[PHOTON_RAYLEIGH] )
            {
                cs += m_cross_sections.h_photon_CS->Rayleigh_Lv_CS[ index ];
            }
            mu_mat [ index ] = cs;
            ++n;
        }
        ++ind_mat;
    }

    // Find the less attenuate material
    ui16 *mumin_ind_mat = new ui16[ nb_bins_E ];
    ui16 ind_bins_E = 0; while ( ind_bins_E < nb_bins_E )
    {
        mumin_ind_mat [ ind_bins_E ] = 0;
        ind_mat = 1; while ( ind_mat < m_materials.h_materials->nb_materials )
        {
            if ( mu_mat [ ind_mat * nb_bins_E + ind_bins_E ] < mu_mat [ mumin_ind_mat[ ind_bins_E ] * nb_bins_E + ind_bins_E ] ) {
                mumin_ind_mat [ ind_bins_E ] = ind_mat;
            }
            ++ind_mat;
        }
        ++ind_bins_E;
    }

    // Init super voxels mumax table vector and material index
    ui16 *sup_vox_ind_mat_table = new ui16[ nbx_sup_vox * nby_sup_vox * nbz_sup_vox * nb_bins_E];
    ui32 ind_sup_vol = 0; while ( ind_sup_vol < nbx_sup_vox * nby_sup_vox * nbz_sup_vox )
    {
        ind_bins_E = 0; while ( ind_bins_E < nb_bins_E ) {
            sup_vox_ind_mat_table [ ind_sup_vol * nb_bins_E + ind_bins_E ] = mumin_ind_mat [ ind_bins_E ];
            ++ind_bins_E;
        }
        ++ind_sup_vol;
    }

    // Find the most attenuate material in each super voxel

    ui32 i, j, k, ii, jj, kk, rest;
    ui32 xy = m_phantom.h_volume->nb_vox_x * m_phantom.h_volume->nb_vox_y;
    ui32 sv_xy = nbx_sup_vox * nby_sup_vox;
    ui32 ind_vol = 0; while ( ind_vol < m_phantom.h_volume->number_of_voxels )
    {
        // Calculate the i, j, k voxel index
        k = ind_vol / xy;
        rest = ind_vol % xy;
        j = rest / m_phantom.h_volume->nb_vox_x;
        i = rest % m_phantom.h_volume->nb_vox_x;
        // Calculate the ii, jj, kk super voxel index
        ii = i / m_nb_bins_sup_voxel;
        jj = j / m_nb_bins_sup_voxel;
        kk = k / m_nb_bins_sup_voxel;
        ind_sup_vol = kk * sv_xy + jj * nbx_sup_vox + ii;

        // super voxel index associated to the the voxel ind_vol
        sup_vox_index[ ind_vol ] = ind_sup_vol;

        ind_mat = m_phantom.h_volume->values[ ind_vol ];

        // Material index associated to the super voxel ind_sup_vol according to E_bins
        ind_bins_E = 0; while ( ind_bins_E < nb_bins_E )
        {
            if ( mu_mat[ sup_vox_ind_mat_table [ ind_sup_vol * nb_bins_E + ind_bins_E ] * nb_bins_E + ind_bins_E ] < mu_mat[ ind_mat  * nb_bins_E + ind_bins_E ] )
            {
                sup_vox_ind_mat_table [ ind_sup_vol * nb_bins_E + ind_bins_E ] = ind_mat;
            }
            ++ind_bins_E;
        }
        ++ind_vol;
    }

    // Reduce the sup_vox_ind_mat table size (removing duplicates)

    std::vector<ui16> red_sup_vox_ind_mat_table(1, sup_vox_ind_mat_table [ 0 ]);
    ui16 *old_to_red_link = new ui16[ nbx_sup_vox * nby_sup_vox * nbz_sup_vox * nb_bins_E ];
    bool ind_not_found;
    old_to_red_link [0] = 0;
    ui32 ind = 1; while ( ind < nbx_sup_vox * nby_sup_vox * nbz_sup_vox * nb_bins_E)
    {
        ind_not_found = true;
        ui16 j = 0; while (j < red_sup_vox_ind_mat_table.size())
        {
            if ( sup_vox_ind_mat_table [ ind ] == red_sup_vox_ind_mat_table [ j ] )
            {
                old_to_red_link [ind] = j;
                ind_not_found = false;
                break;
            }
            ++j;
        }
        if (ind_not_found)
        {
            red_sup_vox_ind_mat_table.push_back(sup_vox_ind_mat_table [ ind ]);
            old_to_red_link [ ind ] = red_sup_vox_ind_mat_table.size() - 1;
        }
        ++ind;
    }

    // Link voxels to the reduced mumax index table
    HANDLE_ERROR( cudaMallocManaged( &(m_mumax_index_table), m_phantom.h_volume->number_of_voxels * nb_bins_E * sizeof( ui16 ) ) );
    ind_vol = 0; while ( ind_vol < m_phantom.h_volume->number_of_voxels )
    {
        ind_bins_E = 0; while ( ind_bins_E < nb_bins_E ) {
            m_mumax_index_table[ ind_vol * nb_bins_E + ind_bins_E ] = old_to_red_link[ sup_vox_index[ ind_vol ]  * nb_bins_E + ind_bins_E ];
            ++ind_bins_E;
        }
        ++ind_vol;
    }

    // Build table using max density  [ 1 / Sum( CS ) ]
    // Init voxels mumax table vector

    ui32 size = red_sup_vox_ind_mat_table.size() * nb_bins_E;
    HANDLE_ERROR( cudaMallocManaged( &(m_mumax_table), size * sizeof( f32 ) ) );

    ind_mat = 0; while ( ind_mat < red_sup_vox_ind_mat_table.size() )
    {
        ui32 j=0; while ( j < nb_bins_E )
        {
            ui32 index = red_sup_vox_ind_mat_table[ ind_mat ] * nb_bins_E + j;
            f32 sum_CS = 0.0;

            if ( mh_params->physics_list[PHOTON_PHOTOELECTRIC] )
            {
                sum_CS += m_cross_sections.h_photon_CS->Photoelectric_Std_CS[ index ];
            }

            if ( mh_params->physics_list[PHOTON_COMPTON] )
            {
                sum_CS += m_cross_sections.h_photon_CS->Compton_Std_CS[ index ];
            }

            if ( mh_params->physics_list[PHOTON_RAYLEIGH] )
            {
                sum_CS += m_cross_sections.h_photon_CS->Rayleigh_Lv_CS[ index ];
            }

            m_mumax_table[ ind_mat * nb_bins_E + j ] = 1.0 / sum_CS;
            ++j;
        }
        ++ind_mat;
    }
}

////:: Main functions

VoxPhanVRTNav::VoxPhanVRTNav ()
{
    // Default doxel size (if 0 = same size to the phantom)
    m_dosel_size_x = 0;
    m_dosel_size_y = 0;
    m_dosel_size_z = 0;

    m_xmin = 0.0; m_xmax = 0.0;
    m_ymin = 0.0; m_ymax = 0.0;
    m_zmin = 0.0; m_zmax = 0.0;

    m_nb_bins_sup_voxel = 10;

    m_flag_vrt = VRT_ANALOG;

    m_materials_filename = "";

    // Init Mu table struct
    mh_mu_table = (VRT_Mu_MuEn_Data*)malloc( sizeof(VRT_Mu_MuEn_Data) );

    mh_mu_table->nb_mat = 0;
    mh_mu_table->nb_bins = 0;
    mh_mu_table->E_max = 0;
    mh_mu_table->E_min = 0;

    mh_mu_table->E_bins = nullptr;
    mh_mu_table->mu = nullptr;
    mh_mu_table->mu_en = nullptr;
    /*
    m_hist_map.interaction = NULL;
    m_hist_map.energy = NULL;

    m_coo_hist_map.x = NULL;
    m_coo_hist_map.y = NULL;
    m_coo_hist_map.z = NULL;
    m_coo_hist_map.energy = NULL;
    m_coo_hist_map.interaction = NULL;
    m_coo_hist_map.nb_data = 0;
*/

    // experimental (Woodcock tracking)
    m_mumax_table = nullptr;
    // experimental (Super Voxel Woodcock tracking)
    m_mumax_index_table = nullptr;

    mh_params = nullptr;
    md_params = nullptr;

    set_name( "VoxPhanVRTNav" );
}

void VoxPhanVRTNav::track_to_in(ParticlesData *d_particles )
{    
    dim3 threads, grid;
    threads.x = mh_params->gpu_block_size;
    grid.x = ( mh_params->size_of_particles_batch + mh_params->gpu_block_size - 1 ) / mh_params->gpu_block_size;

    VPVRTN::kernel_device_track_to_in<<<grid, threads>>> ( d_particles, m_phantom.h_volume->xmin, m_phantom.h_volume->xmax,
                                                           m_phantom.h_volume->ymin, m_phantom.h_volume->ymax,
                                                           m_phantom.h_volume->zmin, m_phantom.h_volume->zmax,
                                                           mh_params->geom_tolerance );
    cudaDeviceSynchronize();
    cuda_error_check ( "Error ", " Kernel_VoxPhanVRT (track to in)" );

}

void VoxPhanVRTNav::track_to_out(ParticlesData *d_particles )
{

    dim3 threads, grid;
    threads.x = mh_params->gpu_block_size;
    grid.x = ( mh_params->size_of_particles_batch + mh_params->gpu_block_size - 1 ) / mh_params->gpu_block_size;


    if ( m_flag_vrt == VRT_ANALOG )
    {
        VPVRTN::kernel_device_track_to_out_analog<<<grid, threads>>>( d_particles,
                                                                      m_phantom.d_volume,
                                                                      m_materials.d_materials,
                                                                      m_cross_sections.d_photon_CS,
                                                                      md_params,
                                                                      m_dose_calculator.d_dose );
    }
    else if ( m_flag_vrt == VRT_TLE )
    {
        VPVRTN::kernel_device_track_to_out_tle<<<grid, threads>>>( d_particles,
                                                                   m_phantom.d_volume,
                                                                   m_materials.d_materials,
                                                                   m_cross_sections.d_photon_CS,
                                                                   md_params,
                                                                   m_dose_calculator.d_dose,
                                                                   md_mu_table );
    }
    else if ( m_flag_vrt == VRT_WOODCOCK )
    {
        VPVRTN::kernel_device_track_to_out_woodcock<<<grid, threads>>>( d_particles,
                                                                        m_phantom.d_volume,
                                                                        m_materials.d_materials,
                                                                        m_cross_sections.d_photon_CS,
                                                                        md_params,
                                                                        m_dose_calculator.d_dose,
                                                                        m_mumax_table );
    }
    else if ( m_flag_vrt == VRT_SVW )
    {
        VPVRTN::kernel_device_track_to_out_svw<<<grid, threads>>>( d_particles,
                                                                   m_phantom.d_volume,
                                                                   m_materials.d_materials,
                                                                   m_cross_sections.d_photon_CS,
                                                                   md_params,
                                                                   m_dose_calculator.d_dose,
                                                                   m_mumax_table,
                                                                   m_mumax_index_table,
                                                                   m_nb_bins_sup_voxel );
    }
    else if ( m_flag_vrt == VRT_SVW_TLE )
    {
        VPVRTN::kernel_device_track_to_out_svw_tle<<<grid, threads>>>( d_particles,
                                                                   m_phantom.d_volume,
                                                                   m_materials.d_materials,
                                                                   m_cross_sections.d_photon_CS,
                                                                   md_params,
                                                                   m_dose_calculator.d_dose,
                                                                   m_mumax_table,
                                                                   m_mumax_index_table,
                                                                   m_nb_bins_sup_voxel,
                                                                   md_mu_table );
    }

    cudaDeviceSynchronize();
    cuda_error_check ( "Error ", " Kernel_VoxPhanVRT" );

    /*
        // Apply seTLE: splitting and determinstic raycasting
        if( m_flag_TLE == seTLE )
        {
            f64 t_start = get_time();
            m_compress_history_map();
            GGcout_time ( "Compress history map", get_time()-t_start );

            threads.x = m_params.data_h.gpu_block_size;//
            grid.x = ( m_coo_hist_map.nb_data + m_params.data_h.gpu_block_size - 1 ) / m_params.data_h.gpu_block_size;

            t_start = get_time();
            VPVRTN::kernel_device_seTLE<<<grid, threads>>> ( d_particles.data_d, m_phantom.data_d,
                                                              m_coo_hist_map, m_dose_calculator.dose,
                                                              m_mu_table, 1000, 0.0 *eV );
            cuda_error_check ( "Error ", " Kernel_device_seTLE" );
            cudaDeviceSynchronize();
            GGcout_time ( "Raycast", get_time()-t_start );
            GGnewline();
        }
*/

}

void VoxPhanVRTNav::load_phantom_from_mhd( std::string filename, std::string range_mat_name )
{
    m_phantom.load_from_mhd( filename, range_mat_name );
}

void VoxPhanVRTNav::write( std::string filename , std::string options )
{
    m_dose_calculator.write( filename, options );
}

// Export density values of the phantom
void VoxPhanVRTNav::export_density_map( std::string filename )
{
    ui32 N = m_phantom.h_volume->number_of_voxels;
    f32 *density = new f32[ N ];
    ui32 i = 0;
    while (i < N)
    {
        density[ i ] = m_materials.h_materials->density[ m_phantom.h_volume->values[ i ] ];
        ++i;
    }

    f32xyz offset = make_f32xyz( m_phantom.h_volume->off_x, m_phantom.h_volume->off_y, m_phantom.h_volume->off_z );
    f32xyz voxsize = make_f32xyz( m_phantom.h_volume->spacing_x, m_phantom.h_volume->spacing_y, m_phantom.h_volume->spacing_z );
    ui32xyz nbvox = make_ui32xyz( m_phantom.h_volume->nb_vox_x, m_phantom.h_volume->nb_vox_y, m_phantom.h_volume->nb_vox_z );

    ImageIO *im_io = new ImageIO;
    im_io->write_3D( filename, density, nbvox, offset, voxsize );
    delete im_io;
}

// Export materials index of the phantom
void VoxPhanVRTNav::export_materials_map( std::string filename )
{
    f32xyz offset = make_f32xyz( m_phantom.h_volume->off_x, m_phantom.h_volume->off_y, m_phantom.h_volume->off_z );
    f32xyz voxsize = make_f32xyz( m_phantom.h_volume->spacing_x, m_phantom.h_volume->spacing_y, m_phantom.h_volume->spacing_z );
    ui32xyz nbvox = make_ui32xyz( m_phantom.h_volume->nb_vox_x, m_phantom.h_volume->nb_vox_y, m_phantom.h_volume->nb_vox_z );

    ImageIO *im_io = new ImageIO;
    im_io->write_3D( filename, m_phantom.h_volume->values, nbvox, offset, voxsize );
    delete im_io;
}

/*
// Export history map from seTLE
void VoxPhanVRTNav::export_history_map( std::string filename )
{
    if ( m_flag_TLE == seTLE )
    {
        f32xyz offset = make_f32xyz( m_phantom.h_volume->off_x, m_phantom.h_volume->off_y, m_phantom.h_volume->off_z );
        f32xyz voxsize = make_f32xyz( m_phantom.h_volume->spacing_x, m_phantom.h_volume->spacing_y, m_phantom.h_volume->spacing_z );
        ui32xyz nbvox = make_ui32xyz( m_phantom.h_volume->nb_vox_x, m_phantom.h_volume->nb_vox_y, m_phantom.h_volume->nb_vox_z );


        // Create an IO object
        ImageIO *im_io = new ImageIO;

        std::string format = im_io->get_extension( filename );
        filename = im_io->get_filename_without_extension( filename );

        // Convert Edep from f64 to f32
        ui32 tot = m_dose_calculator.dose.nb_dosels.x * m_dose_calculator.dose.nb_dosels.y * m_dose_calculator.dose.nb_dosels.z;
        f32 *f32edep = new f32[ tot ];
        ui32 i=0; while ( i < tot )
        {
            f32edep[ i ] = (f32)m_dose_calculator.dose.edep[ i ];
            ++i;
        }

        // Get output name
        std::string int_out( filename + "-Interaction." + format );
        std::string energy_out( filename + "-Energies." + format );

        // Export
        im_io->write_3D( int_out, m_hist_map.interaction, nbvox, offset, voxsize );
        im_io->write_3D( energy_out, m_hist_map.energy, nbvox, offset, voxsize );
    }
    else
    {
        GGwarn << "History map export is only available while using seTLE option!" << GGendl;
    }
}
*/

void VoxPhanVRTNav::initialize (GlobalSimulationParametersData *h_params , GlobalSimulationParametersData *d_params)
{   

    // Check params
    if ( !m_check_mandatory() )
    {
        print_error ( "VoxPhanVRT: missing parameters." );
        exit_simulation();
    }

    // Params
    mh_params = h_params;
    md_params = d_params;

    // Phantom
    m_phantom.set_name( "VoxPhanVRTNav" );
    m_phantom.initialize();

    // Materials table
    m_materials.load_materials_database( m_materials_filename );
    m_materials.initialize( m_phantom.list_of_materials, mh_params );

    // Cross Sections
    m_cross_sections.initialize( m_materials.h_materials, mh_params );

    // Init dose map
    m_dose_calculator.set_voxelized_phantom( m_phantom );
    m_dose_calculator.set_materials( m_materials );
    m_dose_calculator.set_dosel_size( m_dosel_size_x, m_dosel_size_y, m_dosel_size_z );
    m_dose_calculator.set_voi( m_xmin, m_xmax, m_ymin, m_ymax, m_zmin, m_zmax );
    m_dose_calculator.initialize( mh_params );

    // If TLE init mu and mu_en table
    if ( m_flag_vrt == VRT_TLE || m_flag_vrt == VRT_SETLE || m_flag_vrt == VRT_SVW_TLE)
    {
        m_init_mu_table();
    }

    // If Woodcock init mumax table
    if ( m_flag_vrt == VRT_WOODCOCK )
    {
        m_build_mumax_table();
    }

    // If Super Voxel Woodcock init mumax table
    if ( m_flag_vrt == VRT_SVW || m_flag_vrt == VRT_SVW_TLE)
    {
        m_build_svw_mumax_table();
    }


    /*
    // if seTLE init history map
    if ( m_flag_TLE == seTLE )
    {
        HANDLE_ERROR( cudaMallocManaged( &(m_hist_map.interaction), m_phantom.h_volume->number_of_voxels * sizeof( ui32 ) ) );
        HANDLE_ERROR( cudaMallocManaged( &(m_hist_map.energy), m_phantom.h_volume->number_of_voxels * sizeof( f32 ) ) );

        ui32 i=0; while (i < m_phantom.h_volume->number_of_voxels )
        {
            m_hist_map.interaction[ i ] = 0;
            m_hist_map.energy[ i ] = 0.0;
            ++i;
        }
    }
*/

    // Some verbose if required
    if ( mh_params->display_memory_usage )
    {
        ui64 mem = m_get_memory_usage();
        GGcout_mem("VoxPhanVRTNav", mem);
    }

}

void VoxPhanVRTNav::calculate_dose_to_water()
{
    m_dose_calculator.calculate_dose_to_water();

}

void VoxPhanVRTNav::calculate_dose_to_medium()
{
    m_dose_calculator.calculate_dose_to_medium();

}

/// Setting ////////////////////////////////

void VoxPhanVRTNav::set_materials( std::string filename )
{
    m_materials_filename = filename;
}

void VoxPhanVRTNav::set_vrt( std::string kind )
{
    // Transform the name of the process in small letter
    std::transform( kind.begin(), kind.end(), kind.begin(), ::tolower );

    if ( kind == "tle" )
    {
        m_flag_vrt = VRT_TLE;
    }
    else if ( kind == "setle" )
    {
        m_flag_vrt = VRT_SETLE;
    }
    else if ( kind == "analog" )
    {
        m_flag_vrt = VRT_ANALOG;
    }
    else if ( kind == "woodcock" )
    {
        m_flag_vrt = VRT_WOODCOCK;
    }
    else if ( kind == "svw" )
    {
        m_flag_vrt = VRT_SVW;
    }
    else if ( kind == "svw+tle" )
    {
        m_flag_vrt = VRT_SVW_TLE;
    }
    else
    {
        GGcerr << "Variance reduction technique not recognized: '" << kind << "'!" << GGendl;
        exit_simulation();
    }
}

// Set the super voxel size
void VoxPhanVRTNav::set_nb_bins_sup_voxel( ui32 nb_bins_sup_voxel )
{
    m_nb_bins_sup_voxel = nb_bins_sup_voxel;
}

/// Updating /////////////////////////////////

void VoxPhanVRTNav::update_clear_deposition()
{
    m_dose_calculator.clear_deposition();
}

/// Getting //////////////////////////////////

VoxVolumeData<f32> * VoxPhanVRTNav::get_dose_map()
{
    return m_dose_calculator.get_dose_map();
}

AabbData VoxPhanVRTNav::get_bounding_box()
{
    AabbData box;

    box.xmin = m_phantom.h_volume->xmin;
    box.xmax = m_phantom.h_volume->xmax;
    box.ymin = m_phantom.h_volume->ymin;
    box.ymax = m_phantom.h_volume->ymax;
    box.zmin = m_phantom.h_volume->zmin;
    box.zmax = m_phantom.h_volume->zmax;

    return box;
}


#undef DEBUG

#endif
