/*!
  \file xray_source.cc

  \brief This class define a XRay source in GGEMS useful for CT/CBCT simulation

  \author Julien BERT <julien.bert@univ-brest.fr>
  \author Didier BENOIT <didier.benoit@inserm.fr>
  \author LaTIM, INSERM - U1101, Brest, FRANCE
  \version 1.0
  \date Tuesday October 22, 2019
*/

#include "GGEMS/sources/xray_source.hh"
#include "GGEMS/tools/print.hh"

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

XRaySource::XRaySource(void)
: GGEMSSourceDefinition()
{
  GGEMScout("XRaySource", "XRaySource", 1)
    << "Allocation of XRaySource..." << GGEMSendl;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

XRaySource::~XRaySource(void)
{
  GGEMScout("XRaySource", "~XRaySource", 1)
    << "Deallocation of XRaySource..." << GGEMSendl;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void XRaySource::GetPrimaries(cl::Buffer* p_primary_particles)
{
  if (p_primary_particles) std::cout << "Test" << std::endl;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void XRaySource::Initialize(void)
{
  ;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

XRaySource* create_ggems_xray_source(void)
{
  return new XRaySource;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void delete_ggems_xray_source(XRaySource* p_xray_source)
{
  if (p_xray_source) {
    delete p_xray_source;
    p_xray_source = nullptr;
  }
}
