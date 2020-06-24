#ifndef GUARD_GGEMS_GEOMETRIES_GGEMSVOXELIZEDSOLIDSTACK_HH
#define GUARD_GGEMS_GEOMETRIES_GGEMSVOXELIZEDSOLIDSTACK_HH

/*!
  \file GGEMSVoxelizedSolidStack.hh

  \brief Structure storing the stack of data for voxelized and analytical solid

  \author Julien BERT <julien.bert@univ-brest.fr>
  \author Didier BENOIT <didier.benoit@inserm.fr>
  \author LaTIM, INSERM - U1101, Brest, FRANCE
  \version 1.0
  \date Monday March 2, 2020
*/

#include "GGEMS/global/GGEMSConfiguration.hh"
#include "GGEMS/tools/GGEMSTypes.hh"

/*!
  \struct GGEMSVoxelizedSolidData_t
  \brief Structure storing the stack of data for voxelized solid
*/
#ifdef OPENCL_COMPILER
typedef struct __attribute__((aligned (1))) GGEMSVoxelizedSolidData_t
#else
typedef struct PACKED GGEMSVoxelizedSolidData_t
#endif
{
  GGushort3 number_of_voxels_xyz_; /*!< Number of voxel in X, Y and Z [0, 65535] */
  GGuint number_of_voxels_; /*!< Total number of voxels */
  GGdouble3 voxel_sizes_xyz_; /*!< Size of voxels in X, Y and Z */
  GGdouble3 position_xyz_; /*!< Position of phantom in X, Y and Z */
  GGdouble3 border_min_xyz_; /*!< Min. of border in X, Y and Z */
  GGdouble3 border_max_xyz_; /*!< Max. of border in X, Y and Z */
  GGdouble tolerance_; /*!< Geometry tolerance */
  GGuchar navigator_id_; /*!< Navigator index */
} GGEMSVoxelizedSolidData; /*!< Using C convention name of struct to C++ (_t deletion) */

#endif // GUARD_GGEMS_GEOMETRIES_GGEMSVOXELIZEDSOLIDSTACK_HH
