// This file is part of GGEMS
//
// GGEMS is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// GGEMS is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with GGEMS.  If not, see <http://www.gnu.org/licenses/>.
//
// GGEMS Copyright (C) 2013-2014 Julien Bert

#ifndef SPHERE_CU
#define SPHERE_CU

#include "sphere.cuh"

Sphere::Sphere() {}

Sphere::Sphere(float ox, float oy, float oz, float rad,
               std::string mat_name, std::string obj_name) {

    // Sphere parameters
    cx = ox;
    cy = oy;
    cz = oz;
    radius = rad;
    material_name = mat_name;
    object_name = obj_name;

    // define de the bounding box
    xmin = ox-radius;
    xmax = ox+radius;
    ymin = oy-radius;
    ymax = oy+radius;
    zmin = oz-radius;
    zmax = oz+radius;
}


#endif
