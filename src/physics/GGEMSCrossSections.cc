/*!
  \file GGEMSCrossSections.cc

  \brief GGEMS class handling the cross sections tables

  \author Julien BERT <julien.bert@univ-brest.fr>
  \author Didier BENOIT <didier.benoit@inserm.fr>
  \author LaTIM, INSERM - U1101, Brest, FRANCE
  \version 1.0
  \date Tuesday March 31, 2020
*/

#include "GGEMS/physics/GGEMSCrossSections.hh"
#include "GGEMS/physics/GGEMSComptonScattering.hh"
#include "GGEMS/physics/GGEMSPhotoElectricEffect.hh"
#include "GGEMS/physics/GGEMSRayleighScattering.hh"
#include "GGEMS/tools/GGEMSTools.hh"
#include "GGEMS/materials/GGEMSMaterials.hh"
#include "GGEMS/physics/GGEMSProcessesManager.hh"
#include "GGEMS/tools/GGEMSRAMManager.hh"
#include "GGEMS/maths/GGEMSMathAlgorithms.hh"

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

GGEMSCrossSections::GGEMSCrossSections(void)
{
  GGcout("GGEMSCrossSections", "GGEMSCrossSections", 3) << "Allocation of GGEMSCrossSections..." << GGendl;
  is_process_activated_.resize(NUMBER_PROCESSES);
  for (auto&& i : is_process_activated_) i = false;

  // Get the OpenCL manager
  GGEMSOpenCLManager& opencl_manager = GGEMSOpenCLManager::GetInstance();

  // Get the RAM manager
  GGEMSRAMManager& ram_manager = GGEMSRAMManager::GetInstance();

  // Allocating memory for cross section tables on host and device
  particle_cross_sections_cl_ = opencl_manager.Allocate(nullptr, sizeof(GGEMSParticleCrossSections), CL_MEM_READ_WRITE);
  ram_manager.AddProcessRAMMemory(sizeof(GGEMSParticleCrossSections));

  particle_cross_sections_.reset(new GGEMSParticleCrossSections());
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

GGEMSCrossSections::~GGEMSCrossSections(void)
{
  GGcout("GGEMSCrossSections", "~GGEMSCrossSections", 3) << "Deallocation of GGEMSCrossSections..." << GGendl;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSCrossSections::AddProcess(std::string const& process_name, std::string const& particle_type, bool const& is_secondary)
{
  GGcout("GGEMSCrossSections", "AddProcess", 0) << "Adding " << process_name << " scattering process..." << GGendl;

  if (process_name == "Compton") {
    if (!is_process_activated_.at(COMPTON_SCATTERING)) {
      em_processes_list_.push_back(std::make_shared<GGEMSComptonScattering>(particle_type, is_secondary));
      is_process_activated_.at(COMPTON_SCATTERING) = true;
    }
    else {
      GGwarn("GGEMSCrossSections", "AddProcess", 3) << "Compton scattering process already activated!!!" << GGendl;
    }
  }
  else if (process_name == "Photoelectric") {
    if (!is_process_activated_.at(PHOTOELECTRIC_EFFECT)) {
      em_processes_list_.push_back(std::make_shared<GGEMSPhotoElectricEffect>(particle_type, is_secondary));
      is_process_activated_.at(PHOTOELECTRIC_EFFECT) = true;
    }
    else {
      GGwarn("GGEMSCrossSections", "AddProcess", 3) << "PhotoElectric effect process already activated!!!" << GGendl;
    }
  }
  else if (process_name == "Rayleigh") {
    if (!is_process_activated_.at(RAYLEIGH_SCATTERING)) {
      em_processes_list_.push_back(std::make_shared<GGEMSRayleighScattering>(particle_type, is_secondary));
      is_process_activated_.at(RAYLEIGH_SCATTERING) = true;
    }
    else {
      GGwarn("GGEMSCrossSections", "AddProcess", 3) << "PhotoElectric effect process already activated!!!" << GGendl;
    }
  }
  else {
    std::ostringstream oss(std::ostringstream::out);
    oss << "Unknown process!!! The available processes in GGEMS are:" << std::endl;
    oss << "    * For incident gamma:" << std::endl;
    oss << "        - 'Compton'" << std::endl;
    oss << "        - 'Photoelectric'" << std::endl;
    oss << "        - 'Rayleigh'" << std::endl;
    GGEMSMisc::ThrowException("GGEMSCrossSections", "AddProcess", oss.str());
  }
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSCrossSections::Initialize(GGEMSMaterials const* materials)
{
  GGcout("GGEMSCrossSections", "Initialize", 0) << "Initializing cross section tables..." << GGendl;

  // Get the OpenCL manager
  GGEMSOpenCLManager& opencl_manager = GGEMSOpenCLManager::GetInstance();

  // Get the process manager
  GGEMSProcessesManager& process_manager = GGEMSProcessesManager::GetInstance();

  GGEMSParticleCrossSections* particle_cross_sections_device = opencl_manager.GetDeviceBuffer<GGEMSParticleCrossSections>(particle_cross_sections_cl_.get(), sizeof(GGEMSParticleCrossSections));

  // Storing information for process manager
  GGushort const kNBins = process_manager.GetCrossSectionTableNumberOfBins();
  GGfloat const kMinEnergy = process_manager.GetCrossSectionTableMinEnergy();
  GGfloat const kMaxEnergy = process_manager.GetCrossSectionTableMaxEnergy();

  particle_cross_sections_device->number_of_bins_ = kNBins;
  particle_cross_sections_device->min_energy_ = kMinEnergy;
  particle_cross_sections_device->max_energy_ = kMaxEnergy;
  for (std::size_t i = 0; i < materials->GetNumberOfMaterials(); ++i) {
    #ifdef _WIN32
    strcpy_s(reinterpret_cast<char*>(particle_cross_sections_device->material_names_[i]), 32, (materials->GetMaterialName(i)).c_str());
    #else
    strcpy(reinterpret_cast<char*>(particle_cross_sections_device->material_names_[i]), (materials->GetMaterialName(i)).c_str());
    #endif
  }

  // Storing information from materials
  particle_cross_sections_device->number_of_materials_ = static_cast<GGuchar>(materials->GetNumberOfMaterials());

  // Filling energy table with log scale
  GGfloat const kSlope = logf(kMaxEnergy/kMinEnergy);
  for (GGushort i = 0; i < kNBins; ++i) {
    particle_cross_sections_device->energy_bins_[i] = kMinEnergy * expf(kSlope * (static_cast<float>(i) / (kNBins-1.0f))) * MeV;
  }

  // Release pointer
  opencl_manager.ReleaseDeviceBuffer(particle_cross_sections_cl_.get(), particle_cross_sections_device);

  // Loop over the activated physic processes and building tables
  for (auto&& i : em_processes_list_)
    i->BuildCrossSectionTables(particle_cross_sections_cl_, materials->GetMaterialTables());

  // Copy data from device to RAM memory (optimization for python users)
  LoadPhysicTablesOnHost();
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void GGEMSCrossSections::LoadPhysicTablesOnHost(void)
{
  GGcout("GGEMSCrossSections", "LoadPhysicTablesOnHost", 1) << "Loading physic tables from OpenCL device to host (RAM)..." << GGendl;

  // Get the OpenCL manager
  GGEMSOpenCLManager& opencl_manager = GGEMSOpenCLManager::GetInstance();

  GGEMSParticleCrossSections* particle_cross_sections_device = opencl_manager.GetDeviceBuffer<GGEMSParticleCrossSections>(particle_cross_sections_cl_.get(), sizeof(GGEMSParticleCrossSections));

  particle_cross_sections_->number_of_bins_ = particle_cross_sections_device->number_of_bins_;
  particle_cross_sections_->number_of_materials_ = particle_cross_sections_device->number_of_materials_;
  particle_cross_sections_->min_energy_ = particle_cross_sections_device->min_energy_;
  particle_cross_sections_->max_energy_ = particle_cross_sections_device->max_energy_;

  for(GGuchar i = 0; i < particle_cross_sections_->number_of_materials_; ++i) {
    for(GGuchar j = 0; j < 32; ++j) {
      particle_cross_sections_->material_names_[i][j] = particle_cross_sections_device->material_names_[i][j];
    }
  }

  for(GGushort i = 0; i < particle_cross_sections_->number_of_bins_; ++i) {
    particle_cross_sections_->energy_bins_[i] = particle_cross_sections_device->energy_bins_[i];
  }

  particle_cross_sections_->number_of_activated_photon_processes_ = particle_cross_sections_device->number_of_activated_photon_processes_;

  for(GGuchar i = 0; i < NUMBER_PHOTON_PROCESSES; ++i) {
    particle_cross_sections_->index_photon_cs_[i] = particle_cross_sections_device->index_photon_cs_[i];
  }

  for(GGuchar j = 0; j < NUMBER_PHOTON_PROCESSES; ++j) {
    for(GGuint i = 0; i < 256*MAX_CROSS_SECTION_TABLE_NUMBER_BINS; ++i) {
      particle_cross_sections_->photon_cross_sections_[j][i] = particle_cross_sections_device->photon_cross_sections_[j][i];
    }
  }

  for(GGuchar j = 0; j < NUMBER_PHOTON_PROCESSES; ++j) {
    for(GGuint i = 0; i < 101*MAX_CROSS_SECTION_TABLE_NUMBER_BINS; ++i) {
      particle_cross_sections_->photon_cross_sections_per_atom_[j][i] = particle_cross_sections_device->photon_cross_sections_per_atom_[j][i];
    }
  }

  // Release pointer
  opencl_manager.ReleaseDeviceBuffer(particle_cross_sections_cl_.get(), particle_cross_sections_device);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

GGfloat GGEMSCrossSections::GetPhotonCrossSection(std::string const& process_name, std::string const& material_name, GGfloat const& energy, std::string const& unit) const
{
  // Get min and max energy in the table, and number of bins
  GGfloat const kMinEnergy = particle_cross_sections_->min_energy_;
  GGfloat const kMaxEnergy = particle_cross_sections_->max_energy_;
  GGuint const kNumberOfBins = particle_cross_sections_->number_of_bins_;
  GGuchar const kNumberMaterials = particle_cross_sections_->number_of_materials_;

  // Converting energy
  GGfloat const kEnergyMeV = EnergyUnit(energy, unit);

  if (kEnergyMeV < kMinEnergy || kEnergyMeV > kMaxEnergy) {
    std::ostringstream oss(std::ostringstream::out);
    oss << "Problem energy: " << kEnergyMeV << " " << unit << " is not in the range [" << kMinEnergy << ", " << kMaxEnergy << "] MeV!!!" << std::endl;
    GGEMSMisc::ThrowException("GGEMSCrossSections", "GetPhotonCrossSection", oss.str());
  }

  // Get the process id
  GGuchar process_id = 0;
  if (process_name == "Compton") {
    process_id = COMPTON_SCATTERING;
  }
  else if (process_name == "Photoelectric") {
    process_id = PHOTOELECTRIC_EFFECT;
  }
  else if (process_name == "Rayleigh") {
    process_id = RAYLEIGH_SCATTERING;
  }
  else {
    std::ostringstream oss(std::ostringstream::out);
    oss << "Unknown process!!! The available processes for photon in GGEMS are:" << std::endl;
    oss << "    - 'Compton'" << std::endl;
    oss << "    - 'Photoelectric'" << std::endl;
    oss << "    - 'Rayleigh'" << std::endl;
    GGEMSMisc::ThrowException("GGEMSCrossSections", "GetPhotonCrossSection", oss.str());
  }

  // Get id of material
  GGuint mat_id = 0;
  for (GGuchar i = 0; i < kNumberMaterials; ++i) {
    if (strcmp(material_name.c_str(), reinterpret_cast<char*>(particle_cross_sections_->material_names_[i])) == 0) {
      mat_id = i;
      break;
    }
  }

  // Get density of material
  GGEMSMaterialsDatabaseManager& material_database_manager = GGEMSMaterialsDatabaseManager::GetInstance();
  GGfloat const kDensity = material_database_manager.GetMaterial(material_name).density_;

  // Computing the energy bin
  GGuint const kEnergyBin = BinarySearchLeft(kEnergyMeV, particle_cross_sections_->energy_bins_, kNumberOfBins, 0, 0);

  // Compute cross section using linear interpolation
  GGfloat const kEnergyA = particle_cross_sections_->energy_bins_[kEnergyBin];
  GGfloat const kEnergyB = particle_cross_sections_->energy_bins_[kEnergyBin+1];
  GGfloat const kCSA = particle_cross_sections_->photon_cross_sections_[process_id][kEnergyBin + kNumberOfBins*mat_id];
  GGfloat const kCSB = particle_cross_sections_->photon_cross_sections_[process_id][kEnergyBin+1 + kNumberOfBins*mat_id];

  GGfloat const kCS = LinearInterpolation(kEnergyA, kCSA, kEnergyB, kCSB, kEnergyMeV);

  return (kCS/kDensity) / (cm2/g);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

GGEMSCrossSections* create_ggems_cross_sections(void)
{
  return new(std::nothrow) GGEMSCrossSections;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void add_process_ggems_cross_sections(GGEMSCrossSections* cross_sections, char const* process_name, char const* particle_name, bool const is_secondary)
{
  cross_sections->AddProcess(process_name, particle_name, is_secondary);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

void initialize_ggems_cross_sections(GGEMSCrossSections* cross_sections, GGEMSMaterials* materials)
{
  cross_sections->Initialize(materials);
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

float get_cs_cross_sections(GGEMSCrossSections* cross_sections, char const* process_name, char const* material_name, GGfloat const energy, char const* unit)
{
  return cross_sections->GetPhotonCrossSection(process_name, material_name, energy, unit);
}
