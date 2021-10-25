# ************************************************************************
# * This file is part of GGEMS.                                          *
# *                                                                      *
# * GGEMS is free software: you can redistribute it and/or modify        *
# * it under the terms of the GNU General Public License as published by *
# * the Free Software Foundation, either version 3 of the License, or    *
# * (at your option) any later version.                                  *
# *                                                                      *
# * GGEMS is distributed in the hope that it will be useful,             *
# * but WITHOUT ANY WARRANTY; without even the implied warranty of       *
# * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        *
# * GNU General Public License for more details.                         *
# *                                                                      *
# * You should have received a copy of the GNU General Public License    *
# * along with GGEMS.  If not, see <https://www.gnu.org/licenses/>.      *
# *                                                                      *
# ************************************************************************

import argparse
from ggems import *

# ------------------------------------------------------------------------------
# Read arguments
parser = argparse.ArgumentParser()
parser.add_argument('-v', '--verbose', required=False, type=int, default=0, help="Set level of verbosity")
parser.add_argument('-s', '--seed', required=False, type=int, default=777, help="Seed of pseudo generator number")
parser.add_argument('-o', '--ogl', required=False, action='store_true', help="Activating OpenGL visu")
args = parser.parse_args()

# Getting arguments
verbosity_level = args.verbose
seed = args.seed
is_ogl = args.ogl

# ------------------------------------------------------------------------------
# STEP 0: Level of verbosity during computation
GGEMSVerbosity(verbosity_level)

# ------------------------------------------------------------------------------
# STEP 1: Calling C++ singleton
opengl_manager = GGEMSOpenGLManager()
opencl_manager = GGEMSOpenCLManager()
materials_database_manager = GGEMSMaterialsDatabaseManager()

# ------------------------------------------------------------------------------
# STEP 2: Params for visualization
opengl_manager.set_window_dimensions(1200, 800)
opengl_manager.set_msaa(8)

# ------------------------------------------------------------------------------
# STEP 3: Choosing an OpenCL device
opencl_manager.set_device_to_activate("all")

# ------------------------------------------------------------------------------
# STEP 4: Setting GGEMS materials
materials_database_manager.set_materials('data/materials.txt')

# ------------------------------------------------------------------------------
# STEP 5: GGEMS simulation
ggems = GGEMS(is_ogl)
ggems.opencl_verbose(False)
ggems.material_database_verbose(False)
ggems.navigator_verbose(False)
ggems.source_verbose(False)
ggems.memory_verbose(False)
ggems.process_verbose(False)
ggems.range_cuts_verbose(False)
ggems.random_verbose(False)
ggems.profiling_verbose(False)
ggems.tracking_verbose(False, 0)

# Initializing the GGEMS simulation
ggems.initialize(seed)

# Start GGEMS simulation
# ggems.run()

# ------------------------------------------------------------------------------
# STEP 6: Exit safely
clean_safely()
exit()
