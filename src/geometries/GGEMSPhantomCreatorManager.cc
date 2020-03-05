/*!
  \file GGEMSPhantomCreatorManager.cc

  \brief Singleton class generating voxelized phantom from analytical volume

  \author Julien BERT <julien.bert@univ-brest.fr>
  \author Didier BENOIT <didier.benoit@inserm.fr>
  \author LaTIM, INSERM - U1101, Brest, FRANCE
  \version 1.0
  \date Thursday January 9, 2020
*/

#include <algorithm>

#include "GGEMS/geometries/GGEMSPhantomCreatorManager.hh"
#include "GGEMS/tools/GGEMSPrint.hh"
#include "GGEMS/tools/GGEMSTools.hh"
#include "GGEMS/tools/GGEMSSystemOfUnits.hh"
#include "GGEMS/io/GGEMSMHDImage.hh"

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

GGEMSPhantomCreatorManager::GGEMSPhantomCreatorManager(void)
: element_sizes_(GGdouble3{{0.0, 0.0, 0.0}}),
  phantom_dimensions_(GGuint3{{0, 0, 0}}),
  number_elements_(0),
  data_type_("MET_FLOAT"),
  material_("Air"),
  output_image_filename_(""),
  output_range_to_material_filename_(""),
  voxelized_phantom_(nullptr),
  opencl_manager_(GGEMSOpenCLManager::GetInstance())
{
  GGcout("GGEMSPhantomCreatorManager", "GGEMSPhantomCreatorManager", 3) << "Allocation of Phantom Creator Manager singleton..." << GGendl;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

GGEMSPhantomCreatorManager::~GGEMSPhantomCreatorManager(void)
{
  GGcout("GGEMSPhantomCreatorManager", "~GGEMSPhantomCreatorManager", 3) << "Deallocation of Phantom Creator Manager singleton..." << GGendl;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::SetElementSizes(GGdouble const& voxel_width, GGdouble const& voxel_height, GGdouble const& voxel_depth, char const* unit)
{
  element_sizes_.s[0] = GGEMSUnits::BestDistanceUnit(voxel_width, unit);
  element_sizes_.s[1] = GGEMSUnits::BestDistanceUnit(voxel_height, unit);
  element_sizes_.s[2] = GGEMSUnits::BestDistanceUnit(voxel_depth, unit);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::SetPhantomDimensions(GGuint const& phantom_width, GGuint const& phantom_height, GGuint const& phantom_depth)
{
  phantom_dimensions_.s[0] = phantom_width;
  phantom_dimensions_.s[1] = phantom_height;
  phantom_dimensions_.s[2] = phantom_depth;
  number_elements_ = phantom_width * phantom_height * phantom_depth;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::SetMaterial(char const* material)
{
  material_ = material;

  // Store the material in map
  label_to_material_.insert(std::make_pair(0.0f, material_));
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::SetDataType(std::string const& data_type)
{
  data_type_ = data_type;

  // Convert raw data to material id data
  if (data_type_.compare("MET_CHAR") && data_type_.compare("MET_UCHAR") && data_type_.compare("MET_SHORT") && data_type_.compare("MET_USHORT") && data_type_.compare("MET_INT") && data_type_.compare("MET_UINT") && data_type_.compare("MET_FLOAT")) {
    std::ostringstream oss(std::ostringstream::out);
    oss << "Your type in not compatible. The type has to be:" << std::endl;
    oss << "    - MET_CHAR" << std::endl;
    oss << "    - MET_UCHAR" << std::endl;
    oss << "    - MET_SHORT" << std::endl;
    oss << "    - MET_USHORT" << std::endl;
    oss << "    - MET_INT" << std::endl;
    oss << "    - MET_UINT" << std::endl;
    oss << "    - MET_FLOAT" << std::endl;
    GGEMSMisc::ThrowException("GGEMSPhantomCreatorManager", "SetDataType", oss.str());
  }
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::AddLabelAndMaterial(GGfloat const& label, std::string const& material)
{
  GGcout("GGEMSPhantomCreatorManager", "AddLabelAndMaterial", 3) << "Adding new material and label..." << GGendl;

  // Insert label and check if the label exists already
  auto const [iter, success] = label_to_material_.insert(std::make_pair(label, material));
  if (!success) {
    std::ostringstream oss(std::ostringstream::out);
    oss << "The label: " << iter->first << " already exists...";
    GGEMSMisc::ThrowException("GGEMSPhantomCreatorManager", "AddLabelAndMaterial", oss.str());
  }
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::SetOutputImageFilename(char const* output_image_filename)
{
  output_image_filename_ = output_image_filename;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::SetRangeToMaterialDataFilename(char const* output_range_to_material_filename)
{
  output_range_to_material_filename_ = output_range_to_material_filename;

  // Adding suffix
  output_range_to_material_filename_ += ".txt";
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::CheckParameters(void) const
{
  GGcout("GGEMSPhantomCreatorManager", "CheckParameters", 3) << "Checking parameters for phantom creator manager..." << GGendl;

  // Checking phantom dimensions
  if (phantom_dimensions_.s[0] == 0 && phantom_dimensions_.s[1] == 0 && phantom_dimensions_.s[2] == 0) {
    GGEMSMisc::ThrowException("GGEMSPhantomCreatorManager", "CheckParameters", "Phantom dimensions have to be > 0!!!");
  }

  // Checking size of voxels
  if (GGEMSMisc::IsEqual(element_sizes_.s[0], 0.0) && GGEMSMisc::IsEqual(element_sizes_.s[1], 0.0) && GGEMSMisc::IsEqual(element_sizes_.s[2], 0.0)) {
    GGEMSMisc::ThrowException("GGEMSPhantomCreatorManager", "CheckParameters", "Phantom voxel sizes have to be > 0.0!!!");
    }

  // Checking output name
  if (output_image_filename_.empty()) {
    GGEMSMisc::ThrowException("GGEMSPhantomCreatorManager", "CheckParameters", "A output image filename has to be done to phantom manager!!!");
  }

  // Checking range to material data name
  if (output_range_to_material_filename_.empty()) {
    GGEMSMisc::ThrowException("GGEMSPhantomCreatorManager", "CheckParameters", "A output range to material data filename has to be done to phantom manager!!!");
  }
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::Initialize(void)
{
  GGcout("GGEMSPhantomCreatorManager", "Initialize", 3) << "Initializing phantom creator manager..." << GGendl;

  // Check mandatory parameters
  CheckParameters();

  if (!data_type_.compare("MET_CHAR")) AllocateImage<char>();
  else if (!data_type_.compare("MET_UCHAR")) AllocateImage<unsigned char>();
  else if (!data_type_.compare("MET_SHORT")) AllocateImage<GGshort>();
  else if (!data_type_.compare("MET_USHORT")) AllocateImage<GGushort>();
  else if (!data_type_.compare("MET_INT")) AllocateImage<GGint>();
  else if (!data_type_.compare("MET_UINT")) AllocateImage<GGuint>();
  else if (!data_type_.compare("MET_FLOAT")) AllocateImage<GGfloat>();
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::Write(void)
{
  // Writing output image
  WriteMHDImage();

  // Writing the range to material file
  WriteRangeToMaterialFile();
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::WriteRangeToMaterialFile(void)
{
  GGcout("GGEMSPhantomCreatorManager", "WriteRangeToMaterialFile", 3) << "Writing range to material text file..." << GGendl;

  GGcout("GGEMSPhantomCreatorManager", "WriteRangeToMaterialFile", 0) << "List of label and material:" << GGendl;
  for(auto&& i : label_to_material_) {
    GGcout("GGEMSPhantomCreatorManager", "WriteRangeToMaterialFile", 0) << "    * Material: " << i.second << ", label: " << i.first << GGendl;
  }

  // Write file
  std::ofstream range_to_data_stream(output_range_to_material_filename_, std::ios::out);
  for(auto&& i : label_to_material_) {
    range_to_data_stream << i.first << " " << i.first << " " << i.second << std::endl;
  }
  range_to_data_stream.close();
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSPhantomCreatorManager::WriteMHDImage(void) const
{
  GGcout("GGEMSPhantomCreatorManager", "WriteMHDImage", 3) << "Writing MHD output file..." << GGendl;

  // Write MHD file
  GGEMSMHDImage mhdImage;
  mhdImage.SetBaseName(output_image_filename_);
  mhdImage.SetDataType(data_type_);
  mhdImage.SetDimensions(phantom_dimensions_);
  mhdImage.SetElementSizes(element_sizes_);
  mhdImage.Write(voxelized_phantom_);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

GGEMSPhantomCreatorManager* get_instance_phantom_creator_manager(void)
{
  return &GGEMSPhantomCreatorManager::GetInstance();
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void set_phantom_dimension_phantom_creator_manager(GGEMSPhantomCreatorManager* phantom_creator_manager, GGuint const phantom_width, GGuint const phantom_height, GGuint const phantom_depth)
{
  phantom_creator_manager->SetPhantomDimensions(phantom_width, phantom_height, phantom_depth);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void set_element_sizes_phantom_creator_manager(GGEMSPhantomCreatorManager* phantom_creator_manager, GGdouble const voxel_width, GGdouble const voxel_height, GGdouble const voxel_depth, char const* unit)
{
  phantom_creator_manager->SetElementSizes(voxel_width, voxel_height, voxel_depth, unit);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void set_output_image_filename_phantom_creator_manager(GGEMSPhantomCreatorManager* phantom_creator_manager, char const* output_image_filename)
{
  phantom_creator_manager->SetOutputImageFilename(output_image_filename);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void set_output_range_to_material_filename_phantom_creator_manager(GGEMSPhantomCreatorManager* phantom_creator_manager,char const* output_range_to_material_filename)
{
  phantom_creator_manager->SetRangeToMaterialDataFilename(output_range_to_material_filename);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void initialize_phantom_creator_manager(GGEMSPhantomCreatorManager* phantom_creator_manager)
{
  phantom_creator_manager->Initialize();
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void write_phantom_creator_manager(GGEMSPhantomCreatorManager* phantom_creator_manager)
{
  phantom_creator_manager->Write();
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void set_material_phantom_creator_manager(GGEMSPhantomCreatorManager* phantom_creator_manager, char const* material)
{
  phantom_creator_manager->SetMaterial(material);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void set_data_type_phantom_creator_manager(GGEMSPhantomCreatorManager* phantom_creator_manager, char const* data_type)
{
  phantom_creator_manager->SetDataType(data_type);
}