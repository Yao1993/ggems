#ifndef GUARD_GGEMS_GEOMETRIES_GGEMSSOLID_HH
#define GUARD_GGEMS_GEOMETRIES_GGEMSSOLID_HH

/*!
  \file GGEMSSolid.hh

  \brief GGEMS class for solid. This class store geometry about phantom or detector

  \author Julien BERT <julien.bert@univ-brest.fr>
  \author Didier BENOIT <didier.benoit@inserm.fr>
  \author LaTIM, INSERM - U1101, Brest, FRANCE
  \version 1.0
  \date Tuesday March 2, 2020
*/

#include <limits>
#include <algorithm>

#include "GGEMS/io/GGEMSTextReader.hh"
#include "GGEMS/geometries/GGEMSVoxelizedSolidStack.hh"
#include "GGEMS/tools/GGEMSRAMManager.hh"
#include "GGEMS/navigators/GGEMSNavigatorManager.hh"

/*!
  \class GGEMSSolid
  \brief GGEMS class for solid (voxelized or analytical) informations
*/
class GGEMS_EXPORT GGEMSSolid
{
  public:
    /*!
      \brief GGEMSSolid constructor
    */
    GGEMSSolid(void);

    /*!
      \brief GGEMSSolid destructor
    */
    ~GGEMSSolid(void);

    /*!
      \fn GGEMSSolid(GGEMSSolid const& solid) = delete
      \param solid - reference on the GGEMS solid
      \brief Avoid copy by reference
    */
    GGEMSSolid(GGEMSSolid const& solid) = delete;

    /*!
      \fn GGEMSSolid& operator=(GGEMSSolid const& solid) = delete
      \param solid - reference on the GGEMS solid
      \brief Avoid assignement by reference
    */
    GGEMSSolid& operator=(GGEMSSolid const& solid) = delete;

    /*!
      \fn GGEMSSolid(GGEMSSolid const&& solid) = delete
      \param solid - rvalue reference on the GGEMS solid
      \brief Avoid copy by rvalue reference
    */
    GGEMSSolid(GGEMSSolid const&& solid) = delete;

    /*!
      \fn GGEMSSolid& operator=(GGEMSSolid const&& solid) = delete
      \param solid - rvalue reference on the GGEMS solid
      \brief Avoid copy by rvalue reference
    */
    GGEMSSolid& operator=(GGEMSSolid const&& solid) = delete;

    /*!
      \fn void Initialize(std::shared_ptr<GGEMSMaterials> materials)
      \param materials - pointer on GGEMS materials
      \brief Initialize solid for geometric navigation
    */
    virtual void Initialize(std::shared_ptr<GGEMSMaterials> materials) = 0;

    /*!
      \fn void SetPosition(GGfloat3 const& position_xyz)
      \param position_xyz - position in X, Y and Z
      \brief set a position for solid
    */
    virtual void SetPosition(GGfloat3 const& position_xyz) = 0;

    /*!
      \fn void SetGeometryTolerance(GGfloat const& tolerance)
      \param tolerance - geometry tolerance for computation
      \brief set the geometry tolerance
    */
    virtual void SetGeometryTolerance(GGfloat const& tolerance) = 0;

    /*!
      \fn void SetNavigatorID(std::size_t const& navigator_id)
      \param navigator_id - index of the navigator
      \brief set the navigator index in solid data
    */
    virtual void SetNavigatorID(std::size_t const& navigator_id) = 0;

    /*!
      \fn void PrintInfos(void) const
      \brief printing infos about solid
    */
    virtual void PrintInfos(void) const = 0;

    /*!
      \fn void Distance(void)
      \brief compute distance from particle position to solid and store this distance in OpenCL particle buffer
    */
    virtual void Distance(void) = 0;

    /*!
      \fn void ProjectTo(void)
      \brief Move particles at an entry of solid
    */
    virtual void ProjectTo(void) = 0;

    /*!
      \fn void TrackThrough(void)
      \brief Track particles through solid
    */
    virtual void TrackThrough(void) = 0;

    /*!
      \fn inline std::shared_ptr<cl::Buffer> GetSolidData(void) const
      \brief get the informations about the solid geometry
      \return header data OpenCL pointer about solid
    */
    inline std::shared_ptr<cl::Buffer> GetSolidData(void) const {return solid_data_;};

  protected:
    /*!
      \fn void InitializeKernel(void)
      \brief Initialize kernel for particle solid distance
    */
    virtual void InitializeKernel(void) = 0;

  protected:
    std::shared_ptr<cl::Buffer> solid_data_; /*!< Data about solid */
    std::shared_ptr<cl::Buffer> label_data_; /*!< Pointer storing the buffer about label data */
    std::shared_ptr<cl::Kernel> kernel_distance_; /*!< OpenCL kernel computing distance between particles and solid */
    std::shared_ptr<cl::Kernel> kernel_project_to_; /*!< OpenCL kernel moving particles to solid */
};

#endif // End of GUARD_GGEMS_GEOMETRIES_GGEMSSOLID_HH
